import Foundation
import Testing
@testable import AgentAttentionCore

/// The file transport between the hook emitter and the app.
@Suite("Event store")
final class EventStoreTests {
    private let paths: AppPaths
    private let store: EventStore

    init() throws {
        paths = try Fixture.temporaryPaths()
        store = EventStore(paths: paths)
    }

    deinit {
        try? FileManager.default.removeItem(at: paths.root)
    }

    private func spoolFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.spool.path).filter { $0.hasSuffix(".json") }
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    @Test("Test storage is isolated from real session data")
    func storageIsolation() {
        #expect(!paths.root.path.contains("Application Support/AgentAttention"))
        #expect(AppPaths.resolved(environment: [AppPaths.environmentKey: "/tmp/aa-somewhere-else"]).root.path == "/tmp/aa-somewhere-else")
        #expect(AppPaths.resolved(environment: [:]).root.path.hasSuffix("Application Support/AgentAttention"))
    }

    // MARK: - Durability

    @Test("Reading the spool does not delete it")
    func readingIsNonDestructive() throws {
        try store.write(event: Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "a", at: Fixture.origin))
        let first = store.readSpool()
        #expect(first.events.count == 1)
        #expect(try spoolFileNames().count == 1, "the file survives until it is acknowledged")

        let second = store.readSpool()
        #expect(second.events.count == 1, "an unacknowledged event is offered again")
    }

    @Test("Acknowledging removes exactly the files that were read")
    func acknowledgeRemovesFiles() throws {
        try store.write(event: Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "a", at: Fixture.origin))
        let drained = store.readSpool()
        store.acknowledge(drained.receipts)
        #expect(try spoolFileNames().isEmpty)
        #expect(store.readSpool().events.isEmpty)
    }

    @Test("A crash between reading and saving loses nothing")
    func crashBeforeSaveReplays() throws {
        try store.write(event: Fixture.event(
            session: "s1", signal: .attention, kind: .approval,
            detail: "Permission needed: Bash", at: Fixture.origin, id: "event-1"
        ))

        // First run: reads, ingests… and dies before it can save. Nothing is acknowledged.
        let doomed = store.readSpool()
        let (first, _, _) = makeEngine()
        first.ingest(doomed.events)
        #expect(first.pendingCount == 1)

        // Second run: the file is still there, so the alert comes back.
        let replay = store.readSpool()
        #expect(replay.events.count == 1)
        let (second, _, _) = makeEngine()
        second.ingest(replay.events)
        #expect(second.pendingCount == 1, "the alert survived the crash")
    }

    @Test("A save failure keeps the events for the next attempt")
    func saveFailureKeepsEvents() throws {
        try store.write(event: Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "a", at: Fixture.origin))
        let drained = store.readSpool()

        // Simulate the app's rule: acknowledge only after a successful save.
        var saved = false
        do {
            // A directory where the state file should be makes the write fail.
            try FileManager.default.createDirectory(at: paths.stateFile, withIntermediateDirectories: true)
            try store.save(snapshot: EngineSnapshot(items: [], sessions: [:], recentEventIDs: [], savedAt: Fixture.origin))
            saved = true
        } catch {
            saved = false
        }
        if saved { store.acknowledge(drained.receipts) }

        #expect(saved == false, "writing over a directory must fail rather than silently succeed")
        #expect(try spoolFileNames().count == 1, "an unsaved event is not thrown away")
    }

    @Test("Replaying an already-absorbed event is a no-op")
    func replayAfterSaveIsDeduped() throws {
        let event = Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "a", at: Fixture.origin, id: "event-1")
        try store.write(event: event)

        let (engine, clock, _) = makeEngine()
        let drained = store.readSpool()
        engine.ingest(drained.events)
        try store.save(snapshot: engine.snapshot())
        // Crash *after* the save but before acknowledging: the file is still on disk.

        let revived = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: store.loadSnapshot())
        revived.ingest(store.readSpool().events)
        #expect(revived.allItems().count == 1)
        #expect(revived.allItems().first?.occurrences == 1, "the recently-seen ring caught the replay")
    }

    // MARK: - Round trips

    @Test("An event round-trips with every field we alert on")
    func eventRoundTrip() throws {
        let event = Fixture.event(
            session: "s1", signal: .attention, kind: .approval,
            detail: "Permission needed: Bash", at: Fixture.origin, hookEvent: "Notification"
        )
        try store.write(event: event)
        #expect(store.readSpool().events.first == event)
    }

    @Test("Events come back in time order")
    func eventOrdering() throws {
        try store.write(event: Fixture.event(session: "s1", signal: .attention, kind: .idle, detail: "b", at: Fixture.origin.addingTimeInterval(60)))
        try store.write(event: Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "a", at: Fixture.origin))
        #expect(store.readSpool().events.map(\.detail) == ["a", "b"])
    }

    @Test("Sub-second ordering survives the write/read cycle")
    func subSecondOrderingSurvives() throws {
        let base = Fixture.origin
        try store.write(event: Fixture.event(session: "s1", signal: .attention, kind: .question, detail: "ask", at: base, id: "ask"))
        try store.write(event: Fixture.event(session: "s1", signal: .activity, detail: nil, at: base.addingTimeInterval(0.25), hookEvent: "PostToolUse", id: "answer"))

        let events = store.readSpool().events
        #expect(events.map(\.id) == ["ask", "answer"])
        #expect(events[1].occurredAt > events[0].occurredAt, "same second, different milliseconds")
    }

    // MARK: - Bad input

    @Test("Unreadable spool files are quarantined, not silently swallowed")
    func quarantineBrokenFiles() throws {
        try store.write(event: Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "good", at: Fixture.origin))
        try Data("{ this is not json".utf8).write(to: paths.spool.appendingPathComponent("0000000000000-broken.json"))

        let drained = store.readSpool()
        #expect(drained.events.count == 1, "one bad file must not lose the good ones")
        #expect(drained.quarantined == ["0000000000000-broken.json"])
        #expect(FileManager.default.fileExists(atPath: paths.quarantine.appendingPathComponent("0000000000000-broken.json").path))
        #expect(store.readSpool().quarantined.isEmpty, "the bad file is not reprocessed forever")
    }

    @Test("Valid JSON of the wrong shape is quarantined too")
    func quarantineWrongShape() throws {
        try Data(#"{"hello":"world"}"#.utf8).write(to: paths.spool.appendingPathComponent("0000000000001-wrong.json"))
        let drained = store.readSpool()
        #expect(drained.events.isEmpty)
        #expect(drained.quarantined.count == 1)
    }

    @Test("The spool is capped so a closed app cannot fill the disk")
    func spoolCap() throws {
        let small = EventStore(paths: paths, spoolCap: 5)
        for index in 0..<20 {
            try small.write(event: Fixture.event(
                session: "s1", signal: .attention, kind: .approval,
                detail: "ask \(index)", at: Fixture.origin.addingTimeInterval(Double(index))
            ))
        }
        #expect(try spoolFileNames().count <= 5)
        #expect(small.readSpool().events.compactMap(\.detail).contains("ask 19"), "the newest asks are the ones kept")
    }

    // MARK: - Heartbeats

    @Test("Heartbeats are overwritten per session rather than accumulating")
    func heartbeatOverwrite() throws {
        let identity = Fixture.identity(session: "s1")
        for offset in 0..<10 {
            try store.write(heartbeat: SessionHeartbeat(
                identity: identity,
                lastEventAt: Fixture.origin.addingTimeInterval(Double(offset)),
                lastHookEvent: "PostToolUse",
                lastSignal: .activity
            ))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.sessions.path).count == 1,
                "a tool call per second must not create a file per second")
        #expect(store.readHeartbeats().first?.lastEventAt == Fixture.origin.addingTimeInterval(9))
    }

    @Test("Removing a heartbeat cleans up the session record")
    func heartbeatRemoval() throws {
        try store.write(heartbeat: SessionHeartbeat(
            identity: Fixture.identity(session: "s1"), lastEventAt: Fixture.origin,
            lastHookEvent: "Stop", lastSignal: .attention
        ))
        #expect(store.readHeartbeats().count == 1)
        store.removeHeartbeat(sessionID: "s1")
        #expect(store.readHeartbeats().isEmpty)
    }

    @Test("Orphaned heartbeats are pruned once their process is gone or they are too old")
    func heartbeatPruning() throws {
        let live = Fixture.identity(session: "live", pid: 111)
        let dead = Fixture.identity(session: "dead", pid: 222)
        let ancient = Fixture.identity(session: "ancient", pid: nil, startedAt: nil)

        for identity in [live, dead] {
            try store.write(heartbeat: SessionHeartbeat(
                identity: identity, lastEventAt: Fixture.origin, lastHookEvent: "PostToolUse", lastSignal: .activity
            ))
        }
        try store.write(heartbeat: SessionHeartbeat(
            identity: ancient, lastEventAt: Fixture.origin.addingTimeInterval(-100_000),
            lastHookEvent: "Stop", lastSignal: .attention
        ))

        let liveness = StubLiveness()
        liveness.kill(222)
        #expect(Set(store.pruneHeartbeats(now: Fixture.origin, staleAfter: 43_200, liveness: liveness)) == ["dead", "ancient"])
        #expect(store.readHeartbeats().map(\.identity.sessionID) == ["live"])
    }

    @Test("A pruned session does not come back on the next tick")
    func pruningDoesNotResurrect() throws {
        let dead = Fixture.identity(session: "dead", pid: 222)
        try store.write(heartbeat: SessionHeartbeat(
            identity: dead, lastEventAt: Fixture.origin, lastHookEvent: "PostToolUse", lastSignal: .activity
        ))
        let liveness = StubLiveness()
        liveness.kill(222)

        // Two full maintenance passes in the app's order: prune, then read.
        for _ in 0..<2 {
            store.pruneHeartbeats(now: Fixture.origin, staleAfter: 43_200, liveness: liveness)
            #expect(store.readHeartbeats().isEmpty)
        }
    }

    @Test("A corrupt heartbeat is skipped without killing the rest")
    func corruptHeartbeat() throws {
        try store.write(heartbeat: SessionHeartbeat(
            identity: Fixture.identity(session: "s1"), lastEventAt: Fixture.origin,
            lastHookEvent: "PostToolUse", lastSignal: .activity
        ))
        try Data("not json".utf8).write(to: paths.sessions.appendingPathComponent("zzz-broken.json"))
        #expect(store.readHeartbeats().count == 1)
    }

    @Test("Session ids cannot escape the sessions directory")
    func fileNameSafety() {
        #expect(EventStore.safeFileName("../../etc/passwd") == "______etc_passwd")
        #expect(EventStore.safeFileName("") == "unknown")
        #expect(EventStore.safeFileName("9f2c-4a1b_ok") == "9f2c-4a1b_ok")
        #expect(EventStore.safeFileName(String(repeating: "a", count: 500)).count == 80)
    }

    // MARK: - Files on disk

    @Test("Every file we write is private to this user")
    func filePermissions() throws {
        try store.write(event: Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "a", at: Fixture.origin))
        try store.write(heartbeat: SessionHeartbeat(
            identity: Fixture.identity(session: "s1"), lastEventAt: Fixture.origin,
            lastHookEvent: "Stop", lastSignal: .attention
        ))
        try store.save(snapshot: EngineSnapshot(items: [], sessions: [:], recentEventIDs: [], savedAt: Fixture.origin))

        let spoolFile = paths.spool.appendingPathComponent(try #require(spoolFileNames().first))
        let sessionFile = paths.sessions.appendingPathComponent("s1.json")
        for file in [spoolFile, sessionFile, paths.stateFile] {
            #expect(try mode(of: file) == 0o600, "\(file.lastPathComponent) should be readable only by its owner")
        }
        for directory in [paths.root, paths.spool, paths.sessions] {
            #expect(try mode(of: directory) == 0o700, "\(directory.lastPathComponent) should not be world-readable")
        }
    }

    @Test("The very first write works even though nothing exists yet")
    func firstRunWrites() throws {
        // A brand new root, never created: the atomic write must not need the destination to exist.
        let fresh = AppPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-attention-firstrun")
            .appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: fresh.root) }

        let freshStore = EventStore(paths: fresh)
        try freshStore.save(snapshot: EngineSnapshot(items: [], sessions: [:], recentEventIDs: [], savedAt: Fixture.origin))
        try freshStore.write(event: Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "a", at: Fixture.origin))
        try freshStore.write(heartbeat: SessionHeartbeat(
            identity: Fixture.identity(session: "s1"), lastEventAt: Fixture.origin,
            lastHookEvent: "Stop", lastSignal: .attention
        ))

        #expect(freshStore.loadSnapshot() != nil)
        #expect(freshStore.readSpool().events.count == 1)
        #expect(freshStore.readHeartbeats().count == 1)
    }

    @Test("Concurrent writers do not corrupt a file or leave temporaries behind")
    func concurrentWrites() throws {
        let target = paths.root.appendingPathComponent("contended.json")
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            let payload = try? JSONCoding.encoder.encode(["writer": index])
            if let payload { try? AtomicFile.write(payload, to: target) }
        }

        let data = try Data(contentsOf: target)
        let decoded = try JSONCoding.decoder.decode([String: Int].self, from: data)
        #expect(decoded["writer"] != nil, "whichever writer won, the file is a complete document")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.root.path).filter { $0.hasPrefix(".tmp-") }
        #expect(leftovers.isEmpty, "every temporary was either renamed into place or cleaned up")
    }

    @Test("A snapshot survives a write/read cycle")
    func snapshotRoundTrip() throws {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))
        try store.save(snapshot: engine.snapshot())

        let loaded = try #require(store.loadSnapshot())
        #expect(loaded.items.count == 1)
        #expect(loaded.items.first?.kind == .approval)
    }

    @Test("A corrupt state file is ignored rather than crashing startup")
    func corruptStateFile() throws {
        try Data("{{{".utf8).write(to: paths.stateFile)
        #expect(store.loadSnapshot() == nil)
    }

    // MARK: - App presence

    @Test("App presence is written, read back and cleared")
    func appPresence() throws {
        #expect(store.readAppStatus() == nil)
        let status = AppRunStatus(pid: 4242, pidStartedAt: 1_759_000_000, version: "0.2.0", startedAt: Fixture.origin)
        try store.write(appStatus: status)
        #expect(store.readAppStatus() == status)
        store.clearAppStatus()
        #expect(store.readAppStatus() == nil)
    }

    // MARK: - Config

    @Test("A missing config file falls back to defaults")
    func missingConfig() {
        #expect(AttentionConfig.load(from: paths.configFile) == .default)
    }

    @Test("A partial config keeps defaults for everything else")
    func partialConfig() throws {
        try Data(#"{"speechEnabled":true,"stallThresholdSeconds":42}"#.utf8).write(to: paths.configFile)
        let config = AttentionConfig.load(from: paths.configFile)
        #expect(config.speechEnabled)
        #expect(config.stallThresholdSeconds == 42)
        #expect(config.snoozeDurationSeconds == AttentionConfig.default.snoozeDurationSeconds)
    }

    @Test("A garbage config falls back to defaults instead of failing to start")
    func garbageConfig() throws {
        try Data("nonsense".utf8).write(to: paths.configFile)
        #expect(AttentionConfig.load(from: paths.configFile) == .default)
    }

    @Test("Hostile numbers in the config are clamped on load")
    func hostileConfigClamped() throws {
        try Data(#"""
        {"sweepIntervalSeconds":-5,"maxVisibleCards":-3,"backgroundEvidenceTTLSeconds":-9,
         "snoozeDurationSeconds":-600,"maxItemAgeSeconds":1,"bubbleSize":9999}
        """#.utf8).write(to: paths.configFile)

        let config = AttentionConfig.load(from: paths.configFile)
        #expect(config.sweepIntervalSeconds >= 1, "a zero interval would spin the timer")
        #expect(config.maxVisibleCards >= 1, "a zero card limit would render an empty panel")
        #expect(config.snoozeDurationSeconds >= 10)
        #expect(config.maxItemAgeSeconds >= 60)
        #expect(config.backgroundEvidenceTTLSeconds >= 60,
                "a negative TTL would make every background reading stale on arrival")
        #expect(config.bubbleSize <= 96)
    }

    @Test("The retired stall keys still load and still do nothing")
    func retiredKeysAreInert() throws {
        // A `config.json` written by 0.4 must not stop the app starting, and turning the old
        // switch on must not bring inferred stalls back.
        try Data(#"{"stallThresholdSeconds":42,"wakeGraceSeconds":7,"stallDetectionEnabled":true}"#.utf8)
            .write(to: paths.configFile)
        let config = AttentionConfig.load(from: paths.configFile)

        #expect(config.stallDetectionEnabled, "the value is preserved verbatim")
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: config, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "UserPromptSubmit"))
        clock.advance(12 * 3600)
        engine.sweep()
        #expect(engine.pendingCount == 0, "twelve hours of silence, with the old switch on, is still nothing")
    }

    @Test("Config changes round-trip through disk")
    func configRoundTrip() throws {
        var config = AttentionConfig.default
        config.speechEnabled = true
        config.stallDetectionEnabled = false
        config.includeHookMessages = true
        try config.save(to: paths.configFile)
        #expect(AttentionConfig.load(from: paths.configFile) == config)
    }
}
