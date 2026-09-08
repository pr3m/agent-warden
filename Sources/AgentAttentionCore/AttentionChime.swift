import Foundation

/// The signature sound: two short notes, generated here rather than shipped as a file.
///
/// Generated on purpose. A bundled track means a licence question and a binary blob nobody can
/// diff; a few lines of arithmetic mean the exact waveform is readable, reviewable and testable —
/// its length, its loudness and its shape are all assertions rather than claims about an asset.
///
/// It is deliberately small: a rising perfect fifth, under four tenths of a second, quiet. This is
/// a nudge that something is waiting, not an alarm.
public struct ChimeSound: Sendable, Equatable {
    public let sampleRate: Double
    public let samples: [Float]

    public init(sampleRate: Double, samples: [Float]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// The loudest sample in it. Bounded on purpose: an alert that startles gets muted, and a muted
    /// alert helps nobody.
    public var peak: Float { samples.reduce(0) { Swift.max($0, abs($1)) } }
}

/// Anything that can make the sound. A protocol, so every rule about *when* to play can be tested
/// without a speaker — the test injects a recorder and asserts on what it was asked to do.
public protocol ChimeSounding: AnyObject, Sendable {
    func play(_ sound: ChimeSound)
    /// Stop whatever is sounding, now. Mute is immediate, not "from the next one onwards".
    func stop()
}

public enum AttentionChime {
    public static let sampleRate: Double = 44_100
    /// A5, then E6 — a rising fifth, which reads as a question rather than a verdict.
    public static let noteFrequencies: [Double] = [880.0, 1_318.51]
    public static let noteDuration: TimeInterval = 0.16
    public static let noteGap: TimeInterval = 0.05
    /// Quiet. Roughly a fifth of full scale, so it sits under speech and system sounds.
    public static let peakAmplitude: Float = 0.22
    /// A hard ceiling the generator is checked against, so "short" is a fact and not an intention.
    public static let maximumDuration: TimeInterval = 0.8

    /// The whole waveform, deterministically.
    public static func sound(sampleRate rate: Double = AttentionChime.sampleRate) -> ChimeSound {
        let rate = rate.isFinite && rate >= 8_000 ? Swift.min(rate, 96_000) : AttentionChime.sampleRate
        let perNote = Int((noteDuration * rate).rounded())
        let perGap = Int((noteGap * rate).rounded())
        var samples: [Float] = []
        samples.reserveCapacity(noteFrequencies.count * perNote + perGap)

        for (index, frequency) in noteFrequencies.enumerated() {
            if index > 0 { samples.append(contentsOf: repeatElement(0, count: perGap)) }
            for sample in 0..<perNote {
                let time = Double(sample) / rate
                // Attack then decay, so neither end of a note is a click. A square-edged tone is
                // heard as a tick before it is heard as a note.
                let attack = Swift.min(1.0, time / 0.008)
                let decay = exp(-4.0 * time / noteDuration)
                let value = sin(2 * Double.pi * frequency * time) * attack * decay
                samples.append(Float(value) * peakAmplitude)
            }
        }
        return ChimeSound(sampleRate: rate, samples: samples)
    }

    /// A 16-bit mono WAV, because that is what the platform's simplest player understands.
    ///
    /// Written by hand rather than through an audio session: nothing here configures hardware,
    /// asks for a permission, or records anything.
    public static func wav(_ sound: ChimeSound) -> Data {
        let bitsPerSample = 16
        let channels = 1
        let byteRate = Int(sound.sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let payload = sound.samples.count * blockAlign

        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func uint32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func uint16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF"); uint32(36 + payload); ascii("WAVE")
        ascii("fmt "); uint32(16); uint16(1); uint16(channels)
        uint32(Int(sound.sampleRate)); uint32(byteRate); uint16(blockAlign); uint16(bitsPerSample)
        ascii("data"); uint32(payload)
        for sample in sound.samples {
            // Clamped before conversion: a value outside [-1, 1] would wrap into a loud crackle.
            let clamped = Swift.min(Swift.max(sample, -1), 1)
            uint16(Int(UInt16(bitPattern: Int16(clamped * 32_767))))
        }
        return data
    }
}

/// Which asks are worth a sound.
///
/// The distinction is the same one the panel already makes: something is *asking you* for
/// something, versus something merely reporting where it got to. A turn that finished, a prompt
/// sitting idle, a stall nobody confirmed — those are states, and a state that makes a noise every
/// time is a state you learn to ignore.
public enum AttentionChimePolicy {
    public static func isWorthChiming(_ kind: AttentionKind) -> Bool {
        switch kind {
        case .question, .stageDecision, .approval, .handoff, .error:
            return true
        case .workComplete, .idle, .suspectedStall:
            return false
        }
    }

    /// An inferred signal never sounds, whatever it is called. Guessing out loud is worse than
    /// guessing quietly.
    public static func isWorthChiming(_ item: AttentionItem) -> Bool {
        item.source == .explicit && isWorthChiming(item.kind)
    }
}

/// Decides whether a raised item actually makes a sound — and is the only thing that ever asks the
/// player to.
///
/// Four rules, each of which exists because the alternative is worse:
///
/// - **Silent means silent.** While muted or switched off, nothing plays *and nothing is kept*.
///   There is no backlog to hear later; unmuting is not an announcement.
/// - **Only what survived the cycle.** An ask that was raised and resolved in the same pass is not
///   something you need to look at, so it makes no sound.
/// - **One sound per waiting episode.** A session that reports a question and then a permission
///   while still waiting is one wait, not two.
/// - **A floor between sounds.** Four sessions finishing together is a chime, not a chord.
public final class ChimeScheduler: @unchecked Sendable {
    /// Waiting episodes already announced. Bounded, and small: this only has to outlive a burst.
    public static let maximumRememberedEpisodes = 64

    private let player: ChimeSounding
    private let minimumGap: TimeInterval
    private let lock = NSLock()
    private var lastPlayedAt: Date = .distantPast
    private var announced: [String] = []
    private var announcedSet: Set<String> = []

    private var enabled = false

    /// `soundEnabled && chimeEnabled`. Both, always — the master switch is a master switch.
    ///
    /// Behind the same lock as everything else here: it is written when a preference changes and
    /// read while an alert is being decided, and those are not guaranteed to be the same thread.
    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }

    public init(player: ChimeSounding, minimumGap: TimeInterval = 4) {
        self.player = player
        self.minimumGap = minimumGap
    }

    /// Returns whether it actually played, so a caller can log the truth rather than the intent.
    @discardableResult
    public func consider(_ item: AttentionItem, surviving: Bool, at moment: Date) -> Bool {
        guard surviving, AttentionChimePolicy.isWorthChiming(item) else { return false }

        lock.lock()
        guard enabled,
              !announcedSet.contains(item.episodeID),
              moment.timeIntervalSince(lastPlayedAt) >= minimumGap else {
            lock.unlock()
            return false
        }
        lastPlayedAt = moment
        announcedSet.insert(item.episodeID)
        announced.append(item.episodeID)
        if announced.count > ChimeScheduler.maximumRememberedEpisodes {
            announcedSet.remove(announced.removeFirst())
        }
        lock.unlock()

        player.play(AttentionChime.sound())
        return true
    }

    /// Play once because the user asked to hear it, and change nothing.
    ///
    /// Deliberately not routed through `consider`: a preview is not an attention event, so it does
    /// not use up the burst allowance, does not mark an episode as announced, and does not depend
    /// on whether the chime is switched on — only on the master switch, which the caller checks.
    public func preview() {
        player.play(AttentionChime.sound())
    }

    public func stop() { player.stop() }
}
