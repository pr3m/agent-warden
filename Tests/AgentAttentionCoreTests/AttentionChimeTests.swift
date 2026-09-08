import Foundation
import Testing
@testable import AgentAttentionCore

/// A player that records instead of sounding. No test in this suite makes a noise, on any machine:
/// what is being checked is *when* the app would play, and that is a decision, not a sound.
private final class RecordingPlayer: ChimeSounding, @unchecked Sendable {
    private(set) var played: [ChimeSound] = []
    private(set) var stops = 0
    func play(_ sound: ChimeSound) { played.append(sound) }
    func stop() { stops += 1 }
}

private func item(kind: AttentionKind, episode: String = "e1",
                  source: SignalSource = .explicit,
                  at: Date = Fixture.origin) -> AttentionItem {
    AttentionItem(sessionID: "s1", episodeID: episode, kind: kind, source: source,
                  detail: "detail", firstSeenAt: at, lastSeenAt: at,
                  identity: Fixture.identity(session: "s1"))
}

/// The sound itself: short, quiet, finite, and the same every time.
@Suite("Attention chime sound")
struct AttentionChimeSoundTests {
    @Test("It is a fraction of a second, and provably so")
    func durationIsBounded() {
        let sound = AttentionChime.sound()
        #expect(sound.duration > 0.2, "long enough to be heard as two notes")
        #expect(sound.duration <= AttentionChime.maximumDuration,
                "an alert you have to wait out is an alert you turn off")
        #expect(sound.samples.count == Int(sound.duration * sound.sampleRate))
    }

    @Test("Every sample is a real number inside the range a speaker can take")
    func samplesAreFiniteAndBounded() {
        let sound = AttentionChime.sound()
        #expect(!sound.samples.isEmpty)
        #expect(sound.samples.allSatisfy { $0.isFinite })
        #expect(sound.samples.allSatisfy { abs($0) <= 1 })
        #expect(sound.peak <= AttentionChime.peakAmplitude + 0.001, "quiet by construction")
        #expect(sound.peak > 0.05, "and not so quiet it is inaudible")
    }

    @Test("It fades in and out, so neither end is a click")
    func edgesAreSoft() {
        let sound = AttentionChime.sound()
        #expect(abs(sound.samples.first ?? 1) < 0.01)
        #expect(abs(sound.samples.last ?? 1) < 0.02, "a note cut off mid-swing is heard as a tick")
    }

    @Test("Two notes with a gap between them, not one continuous tone")
    func itIsTwoNotes() {
        let sound = AttentionChime.sound()
        let perNote = Int((AttentionChime.noteDuration * sound.sampleRate).rounded())
        let perGap = Int((AttentionChime.noteGap * sound.sampleRate).rounded())
        func energy(_ range: Range<Int>) -> Float {
            sound.samples[range].reduce(0) { $0 + abs($1) }
        }
        #expect(energy(0..<perNote) > 1, "the first note sounds")
        #expect(energy((perNote + perGap)..<sound.samples.count) > 1, "and so does the second")
        #expect(energy(perNote..<(perNote + perGap)) == 0, "with silence between them")
        #expect(AttentionChime.noteFrequencies.count == 2)
        #expect(AttentionChime.noteFrequencies[1] > AttentionChime.noteFrequencies[0],
                "rising, which reads as a question rather than a verdict")
    }

    @Test("The same sound every time, generated rather than fetched")
    func generationIsDeterministic() {
        #expect(AttentionChime.sound() == AttentionChime.sound())
        #expect(AttentionChime.sound(sampleRate: 22_050).samples.count
                < AttentionChime.sound(sampleRate: 44_100).samples.count)
    }

    @Test("A nonsense sample rate falls back rather than producing something unplayable",
          arguments: [Double.nan, 0, -44_100, 1_000_000])
    func sampleRateIsValidated(_ rate: Double) {
        let sound = AttentionChime.sound(sampleRate: rate)
        #expect(sound.sampleRate >= 8_000 && sound.sampleRate <= 96_000)
        #expect(sound.duration <= AttentionChime.maximumDuration)
        #expect(sound.samples.allSatisfy { $0.isFinite })
    }

    @Test("The encoded form is a real 16-bit mono WAV, sized to its own contents")
    func wavIsWellFormed() {
        let sound = AttentionChime.sound()
        let data = AttentionChime.wav(sound)
        #expect(data.count == 44 + sound.samples.count * 2)
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let declared = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(Int(UInt32(littleEndian: declared)) == data.count - 8)
    }
}

/// When it is allowed to sound — which is the part that decides whether this feature is welcome.
@Suite("Attention chime policy")
struct AttentionChimePolicyTests {
    @Test("A genuine ask can sound", arguments: [
        AttentionKind.question, .stageDecision, .approval, .handoff, .error,
    ])
    func genuineAsksChime(_ kind: AttentionKind) {
        #expect(AttentionChimePolicy.isWorthChiming(kind))
    }

    @Test("A state report never does", arguments: [
        AttentionKind.workComplete, .idle, .suspectedStall,
    ])
    func statesStaySilent(_ kind: AttentionKind) {
        #expect(!AttentionChimePolicy.isWorthChiming(kind),
                "a noise for every finished turn is a noise you learn to ignore")
    }

    @Test("Something we merely inferred stays silent whatever it is called")
    func inferredNeverChimes() {
        #expect(!AttentionChimePolicy.isWorthChiming(item(kind: .question, source: .inferred)))
        #expect(AttentionChimePolicy.isWorthChiming(item(kind: .question, source: .explicit)))
    }

    @Test("Every kind is decided, so a new one cannot arrive undecided")
    func everyKindIsCovered() {
        for kind in AttentionKind.allCases {
            _ = AttentionChimePolicy.isWorthChiming(kind)          // total, not defaulted
        }
        #expect(AttentionKind.allCases.filter(AttentionChimePolicy.isWorthChiming).count == 5)
    }
}

/// The scheduler: the only thing that ever asks for a sound.
@Suite("Attention chime scheduling")
struct AttentionChimeSchedulingTests {
    private func fixture(gap: TimeInterval = 4) -> (ChimeScheduler, RecordingPlayer) {
        let player = RecordingPlayer()
        let scheduler = ChimeScheduler(player: player, minimumGap: gap)
        scheduler.isEnabled = true
        return (scheduler, player)
    }

    @Test("A genuine ask that is still waiting makes the sound")
    func aRealAskSounds() {
        let (scheduler, player) = fixture()
        #expect(scheduler.consider(item(kind: .question), surviving: true, at: Fixture.origin))
        #expect(player.played.count == 1)
        #expect(player.played.first?.duration ?? 0 <= AttentionChime.maximumDuration)
    }

    @Test("Switched off, nothing sounds — and nothing is saved up for later")
    func silenceIsNotABacklog() {
        let (scheduler, player) = fixture()
        scheduler.isEnabled = false

        #expect(!scheduler.consider(item(kind: .question, episode: "e1"), surviving: true, at: Fixture.origin))
        #expect(!scheduler.consider(item(kind: .approval, episode: "e2"), surviving: true, at: Fixture.origin))
        #expect(player.played.isEmpty)

        // Turning it back on is not an announcement: the events that happened while it was off are
        // gone, not queued.
        scheduler.isEnabled = true
        #expect(player.played.isEmpty, "unmuting replays nothing")
        #expect(scheduler.consider(item(kind: .question, episode: "e3"), surviving: true,
                                   at: Fixture.origin.addingTimeInterval(60)),
                "and the next real ask still works")
        #expect(player.played.count == 1)
    }

    @Test("An ask that was resolved in the same pass never sounds")
    func resolvedInTheSamePassIsSilent() {
        let (scheduler, player) = fixture()
        #expect(!scheduler.consider(item(kind: .approval), surviving: false, at: Fixture.origin))
        #expect(player.played.isEmpty,
                "a sound you get up for and find nothing behind is worse than no sound")
    }

    @Test("A state report is refused even when everything else is right", arguments: [
        AttentionKind.workComplete, .idle, .suspectedStall,
    ])
    func statesAreRefused(_ kind: AttentionKind) {
        let (scheduler, player) = fixture()
        #expect(!scheduler.consider(item(kind: kind), surviving: true, at: Fixture.origin))
        #expect(player.played.isEmpty)
    }

    @Test("One waiting episode is one sound, however many signals it collects")
    func oneEpisodeOneSound() {
        let (scheduler, player) = fixture(gap: 0)
        let moment = Fixture.origin
        #expect(scheduler.consider(item(kind: .question, episode: "wait-1"), surviving: true, at: moment))
        #expect(!scheduler.consider(item(kind: .approval, episode: "wait-1"), surviving: true,
                                    at: moment.addingTimeInterval(30)),
                "still the same wait")
        #expect(player.played.count == 1)
        #expect(scheduler.consider(item(kind: .question, episode: "wait-2"), surviving: true,
                                   at: moment.addingTimeInterval(60)),
                "a new wait is a new sound")
        #expect(player.played.count == 2)
    }

    @Test("Four sessions finishing together is a chime, not a chord")
    func burstsAreThrottled() {
        let (scheduler, player) = fixture(gap: 4)
        let moment = Fixture.origin
        for index in 0..<4 {
            _ = scheduler.consider(item(kind: .question, episode: "e\(index)"), surviving: true,
                                   at: moment.addingTimeInterval(Double(index) * 0.2))
        }
        #expect(player.played.count == 1)

        #expect(scheduler.consider(item(kind: .question, episode: "later"), surviving: true,
                                   at: moment.addingTimeInterval(10)),
                "and once the burst has passed, the next ask is heard")
        #expect(player.played.count == 2)
    }

    @Test("What it remembers is bounded")
    func rememberedEpisodesAreBounded() {
        let (scheduler, player) = fixture(gap: 0)
        for index in 0..<(ChimeScheduler.maximumRememberedEpisodes * 3) {
            _ = scheduler.consider(item(kind: .question, episode: "e\(index)"), surviving: true,
                                   at: Fixture.origin.addingTimeInterval(Double(index)))
        }
        #expect(player.played.count == ChimeScheduler.maximumRememberedEpisodes * 3)
        #expect(ChimeScheduler.maximumRememberedEpisodes == 64)
    }

    @Test("A preview plays because it was asked for, and costs nothing else")
    func previewIsSeparate() {
        let (scheduler, player) = fixture(gap: 4)
        scheduler.isEnabled = false
        scheduler.preview()
        #expect(player.played.count == 1, "hearing it does not require having chosen it")

        // It did not use up the burst allowance, and did not mark any episode as announced.
        scheduler.isEnabled = true
        #expect(scheduler.consider(item(kind: .question, episode: "e1"), surviving: true,
                                   at: Fixture.origin))
        #expect(player.played.count == 2)
    }

    @Test("Stopping is passed straight through, so a mute is immediate")
    func stopIsImmediate() {
        let (scheduler, player) = fixture()
        scheduler.stop()
        #expect(player.stops == 1)
    }
}
