import Foundation
import Testing
@testable import AgentAttentionCore

/// Muting has to be a promise, not a preference.
///
/// The rule the user asked for, in three parts: muted means *no* sound including speech; muting
/// must not forget that speech was wanted; and unmuting must not announce anything that happened
/// while it was off. The first two are properties of the config; the third is a property of the
/// queue, which holds items, not a backlog of utterances.
@Suite("Sound and settings")
struct SoundAndSettingsTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-config-\(UUID().uuidString).json")
    }

    @Test("Out of the box, sound is on and speech is off")
    func defaults() {
        #expect(AttentionConfig.default.soundEnabled)
        #expect(!AttentionConfig.default.speechEnabled)
        #expect(!AttentionConfig.default.speechIsAudible)
    }

    @Test("Speech is audible only when both switches are on", arguments: [
        (true, true, true), (true, false, false), (false, true, false), (false, false, false),
    ])
    func bothSwitchesMatter(_ testCase: (sound: Bool, speech: Bool, audible: Bool)) {
        var config = AttentionConfig.default
        config.soundEnabled = testCase.sound
        config.speechEnabled = testCase.speech
        #expect(config.speechIsAudible == testCase.audible)
    }

    @Test("Muting silences speech without forgetting it was wanted")
    func mutingRemembers() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var config = AttentionConfig.default
        config.speechEnabled = true
        config.soundEnabled = false
        try config.save(to: url)

        let reloaded = AttentionConfig.load(from: url)
        #expect(!reloaded.soundEnabled)
        #expect(reloaded.speechEnabled, "the preference survives the mute")
        #expect(!reloaded.speechIsAudible, "but nothing is spoken while muted")

        // Unmuting restores exactly what was set, and turns nothing on that was never asked for.
        var unmuted = reloaded
        unmuted.soundEnabled = true
        #expect(unmuted.speechIsAudible)
    }

    @Test("A mute survives a restart")
    func mutePersists() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var config = AttentionConfig.default
        config.soundEnabled = false
        try config.save(to: url)

        #expect(!AttentionConfig.load(from: url).soundEnabled)
    }

    @Test("Changing one setting leaves every other one alone")
    func writingIsWholeAndLossless() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var config = AttentionConfig.default
        config.snoozeDurationSeconds = 1800
        config.bubbleSize = 72
        config.speechVoiceIdentifier = "com.apple.voice.example"
        config.notifyOnIdle = false
        try config.save(to: url)

        var loaded = AttentionConfig.load(from: url)
        loaded.soundEnabled = false                 // the one change
        try loaded.save(to: url)

        let after = AttentionConfig.load(from: url)
        #expect(!after.soundEnabled)
        #expect(after.snoozeDurationSeconds == 1800)
        #expect(after.bubbleSize == 72)
        #expect(after.speechVoiceIdentifier == "com.apple.voice.example")
        #expect(!after.notifyOnIdle)
    }

    @Test("An older config with no sound key is not silently muted")
    func missingKeyDefaultsToAudible() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
        { "speechEnabled": true, "snoozeDurationSeconds": 900 }
        """.utf8).write(to: url)

        let loaded = AttentionConfig.load(from: url)
        #expect(loaded.soundEnabled, "a file written before muting existed still makes sound")
        #expect(loaded.speechEnabled)
        #expect(loaded.snoozeDurationSeconds == 900)
    }

    @Test("The chime arrives switched off, so an update never starts making noise")
    func chimeIsOptIn() {
        #expect(!AttentionConfig.default.chimeEnabled)
        #expect(!AttentionConfig.default.chimeIsAudible)
        #expect(AttentionConfig.default.soundIsOnButSilent,
                "the master switch permits sound; out of the box nothing is set to make one")
    }

    @Test("An existing config with no chime key stays silent", arguments: [
        #"{ "soundEnabled": true }"#,
        #"{ "soundEnabled": true, "speechEnabled": true }"#,
        #"{ "soundEnabled": true, "chimeEnabled": false }"#,
    ])
    func olderConfigsDoNotGainASound(_ contents: String) throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(contents.utf8).write(to: url)

        let loaded = AttentionConfig.load(from: url)
        #expect(!loaded.chimeEnabled, "a key that was never there reads as off, not as on")
        #expect(!loaded.chimeIsAudible)
    }

    @Test("Reading a config never rewrites it")
    func loadingLeavesTheFileExactlyAsItWas() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // Hand-written, oddly spaced, with a key this version does not know. Nothing about loading
        // it may normalise, reorder or drop a byte of it.
        let original = Data("""
        {"soundEnabled":true,   "speechEnabled": true,
          "somethingAUserAdded": "keep me" }
        """.utf8)
        try original.write(to: url)

        let loaded = AttentionConfig.load(from: url)
        #expect(loaded.speechEnabled)
        #expect(!loaded.chimeEnabled)
        #expect(try Data(contentsOf: url) == original,
                "an install that reads your preferences must not quietly rewrite them")
    }

    @Test("Both switches decide the chime, exactly as they decide speech", arguments: [
        (true, true, true), (true, false, false), (false, true, false), (false, false, false),
    ])
    func chimeNeedsBothSwitches(_ testCase: (sound: Bool, chime: Bool, audible: Bool)) {
        var config = AttentionConfig.default
        config.soundEnabled = testCase.sound
        config.chimeEnabled = testCase.chime
        #expect(config.chimeIsAudible == testCase.audible)
    }

    @Test("Muting the chime remembers it was wanted, and a restart agrees")
    func chimeSurvivesAMuteAndARestart() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var config = AttentionConfig.default
        config.chimeEnabled = true
        config.soundEnabled = false
        try config.save(to: url)

        let after = AttentionConfig.load(from: url)
        #expect(after.chimeEnabled, "the choice is kept")
        #expect(!after.chimeIsAudible, "and it is silent until sound comes back")
        #expect(!AttentionConfig.default.speechEnabled, "speech is untouched by any of this")
    }

    @Test("Muting changes nothing about what raises attention")
    func mutingIsNotSuppression() {
        var config = AttentionConfig.default
        config.soundEnabled = false
        let (engine, clock, _) = makeEngine(config: config)

        engine.ingest(Fixture.event(session: "sess-mute", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))

        #expect(engine.visibleItems(at: clock.now).count == 1,
                "sound is an output channel; it is not a filter on what is true")
    }
}

/// One rule for "does this session need me", used by the panel and by the status report.
///
/// They were two copies of the same `switch`, which is a disagreement waiting to happen: the
/// command line would call a session quiet while the panel called it uncertain, about the same
/// session at the same moment.
@Suite("Attention certainty")
struct AttentionCertaintyTests {
    private func session(_ activity: SessionActivityState,
                         item: String? = nil,
                         hookEvidence: Bool = true,
                         background: BackgroundEvidence? = nil) -> SessionState {
        SessionState(identity: Fixture.identity(session: "sess-alpha"),
                     activity: activity,
                     lastEventAt: Fixture.origin,
                     lastActivityAt: Fixture.origin,
                     currentItemID: item,
                     hasHookEvidence: hookEvidence,
                     background: background)
    }

    @Test("An open request outranks everything else")
    func waitingWins() {
        let state = session(.unknown, item: "item-1")
        #expect(state.attentionCertainty(at: Fixture.origin, ttl: 1800) == .waiting)
    }

    @Test("A session found by a scan says exactly that")
    func discoveredIsItsOwnAnswer() {
        #expect(session(.discovered, hookEvidence: false)
            .attentionCertainty(at: Fixture.origin, ttl: 1800) == .awaitingFirstHook)
    }

    @Test("Working and waiting at the prompt are asking for nothing")
    func quietStates() {
        #expect(session(.working).attentionCertainty(at: Fixture.origin, ttl: 1800) == .none)
        #expect(session(.awaitingUser).attentionCertainty(at: Fixture.origin, ttl: 1800) == .none)
    }

    @Test("A turn that ended with nothing confirming how is uncertain, never quiet")
    func endedWithoutEvidence() {
        #expect(session(.unknown).attentionCertainty(at: Fixture.origin, ttl: 1800) == .uncertain)
        #expect(session(.ended).attentionCertainty(at: Fixture.origin, ttl: 1800) == .uncertain)
    }

    @Test("A pause is quiet only while its reading is still current")
    func pauseExpires() {
        let evidence = BackgroundEvidence(availability: .reported, running: 1,
                                          types: ["shell"], observedAt: Fixture.origin)
        let paused = session(.backgroundWaiting, background: evidence)

        #expect(paused.attentionCertainty(at: Fixture.origin, ttl: 1800) == .none)
        #expect(paused.attentionCertainty(at: Fixture.origin.addingTimeInterval(3600), ttl: 1800) == .uncertain,
                "an hour-old reading is not a statement about now")
    }

    @Test("The status report reads the same rule the panel does")
    func reportAgreesWithTheRule() throws {
        let paths = try Fixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = EventStore(paths: paths)
        let (engine, clock, _) = makeEngine()

        engine.ingest(Fixture.event(session: "sess-asking", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now,
                                    identity: Fixture.identity(session: "sess-asking", project: "alpha", pid: 100)))
        engine.ingest(Fixture.turnComplete(session: "sess-done", at: clock.now,
                                           identity: Fixture.identity(session: "sess-done", project: "beta", pid: 200)))
        try store.save(snapshot: engine.snapshot())

        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: clock.now)
        #expect(!report.sessions.isEmpty)
        for line in report.sessions {
            guard let state = engine.sessions.values.first(where: { $0.identity.sessionID == line.sessionID })
            else { continue }
            #expect(line.attention == state.attentionCertainty(
                at: clock.now, ttl: AttentionConfig.default.backgroundEvidenceTTLSeconds).rawValue)
        }
    }

    /// An existing config.json predates every roam key. It must still load, with roam off by
    /// default in the only sense that matters: sane thresholds, and no invented SSID.
    @Test("Roam settings default safely and an older config still loads")
    func roamDefaults() throws {
        let config = AttentionConfig.default
        #expect(config.roamBatteryThreshold == 10)
        #expect(config.roamHotspotSSID == nil)
        #expect(config.roamNudgeEnabled)
        #expect(config.roamNudgeSnoozeMinutes == 15)

        let old = Data(#"{"soundEnabled": true}"#.utf8)
        let decoded = try JSONCoding.decoder.decode(AttentionConfig.self, from: old)
        #expect(decoded.roamBatteryThreshold == 10)
        #expect(decoded.roamHotspotSSID == nil)
        #expect(decoded.roamNudgeEnabled)
        #expect(decoded.roamNudgeSnoozeMinutes == 15)
        #expect(decoded.soundEnabled, "the one key the old file did carry is still honoured")
    }

    /// A hand-edited threshold outside the policy's range must not silently disable the battery
    /// guard: `RoamPolicy.guardAction` answers `.none` to one, so an unclamped 0 would leave a
    /// roaming Mac with nothing watching the battery. An empty SSID is not a choice of network.
    @Test("Roam settings are clamped to something the guard can actually run at")
    func roamSettingsAreClamped() throws {
        let mangled = Data(#"""
        {"roamBatteryThreshold": 0, "roamNudgeSnoozeMinutes": 0, "roamHotspotSSID": "  "}
        """#.utf8)
        let loaded = try JSONCoding.decoder.decode(AttentionConfig.self, from: mangled).validated()

        #expect(RoamPolicy.thresholdRange.contains(loaded.roamBatteryThreshold))
        #expect(loaded.roamBatteryThreshold == RoamPolicy.thresholdRange.lowerBound)
        #expect(loaded.roamNudgeSnoozeMinutes == AttentionConfig.roamNudgeSnoozeRange.lowerBound)
        #expect(loaded.roamHotspotSSID == nil, "whitespace is not the name of a network")

        let absurd = Data(#"{"roamBatteryThreshold": 200, "roamNudgeSnoozeMinutes": 99999}"#.utf8)
        let capped = try JSONCoding.decoder.decode(AttentionConfig.self, from: absurd).validated()
        #expect(capped.roamBatteryThreshold == RoamPolicy.thresholdRange.upperBound)
        #expect(capped.roamNudgeSnoozeMinutes == AttentionConfig.roamNudgeSnoozeRange.upperBound)

        // The clamp must be a no-op on the shipped defaults, or the defaults are wrong.
        #expect(AttentionConfig.default.validated() == AttentionConfig.default)
    }
}
