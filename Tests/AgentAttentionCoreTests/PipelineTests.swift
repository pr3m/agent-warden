import Foundation
import Testing
@testable import AgentAttentionCore

/// End to end through the real code path a hook takes: raw payload → identity → spool/heartbeat
/// files → engine → queue. Only the process spawn is left out; `Scripts/smoke-test.sh` covers that.
@Suite("Hook to queue pipeline")
final class PipelineTests {
    private let paths: AppPaths
    private let store: EventStore

    init() throws {
        paths = try Fixture.temporaryPaths()
        store = EventStore(paths: paths)
    }

    deinit {
        try? FileManager.default.removeItem(at: paths.root)
    }

    /// Simulates one hook firing: exactly what `aa-emit` does, minus the process spawn.
    private func fire(
        _ payload: [String: Any],
        at moment: Date,
        identity: SessionIdentity,
        config: AttentionConfig = .default,
        override: HookIngestion.Override = HookIngestion.Override()
    ) throws {
        let outcome = HookIngestion.process(payload: payload, identity: identity, now: moment, config: config, override: override)
        try store.write(heartbeat: outcome.heartbeat)
        if let event = outcome.event { try store.write(event: event) }
    }

    /// One pass of the app's refresh loop, in the app's order.
    @discardableResult
    private func cycle(_ engine: AttentionEngine, liveness: LivenessProbing = StubLiveness(), now: Date = Date()) -> [EngineEffect] {
        store.pruneHeartbeats(now: now, staleAfter: engine.config.staleSessionSeconds, liveness: liveness)
        let drained = store.readSpool()
        var effects = engine.ingest(drained.events)
        effects += engine.applyHeartbeats(store.readHeartbeats())
        effects += engine.sweep()
        if (try? store.save(snapshot: engine.snapshot())) != nil {
            store.acknowledge(drained.receipts)
        }
        return effects
    }

    @Test("Two sessions travel from hook payload to queue independently")
    func twoSessionsEndToEnd() throws {
        let (engine, clock, _) = makeEngine()
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)
        let beta = Fixture.identity(session: "sess-beta", project: "beta", pid: 200)

        try fire(["hook_event_name": "SessionStart", "session_id": "sess-alpha", "cwd": alpha.cwd, "source": "startup"], at: clock.now, identity: alpha)
        try fire(["hook_event_name": "SessionStart", "session_id": "sess-beta", "cwd": beta.cwd, "source": "startup"], at: clock.now, identity: beta)
        #expect(cycle(engine, now: clock.now).raisedItems.isEmpty)

        clock.advance(10)
        try fire(["hook_event_name": "PostToolUse", "session_id": "sess-alpha", "cwd": alpha.cwd, "tool_name": "Bash"], at: clock.now, identity: alpha)
        try fire(["hook_event_name": "PostToolUse", "session_id": "sess-beta", "cwd": beta.cwd, "tool_name": "Read"], at: clock.now, identity: beta)
        cycle(engine, now: clock.now)
        #expect(engine.pendingCount == 0, "two busy sessions stay silent")

        clock.advance(5)
        try fire([
            "hook_event_name": "Notification", "session_id": "sess-alpha", "cwd": alpha.cwd,
            "notification_type": "permission_prompt", "message": "Claude needs your permission",
        ], at: clock.now, identity: alpha)
        try fire(["hook_event_name": "Stop", "session_id": "sess-beta", "cwd": beta.cwd,
                  "background_tasks": [], "session_crons": []], at: clock.now, identity: beta)

        #expect(cycle(engine, now: clock.now).raisedItems.count == 2)
        #expect(engine.visibleItems().map(\.kind) == [.approval, .workComplete])
        #expect(engine.visibleItems().map(\.identity.projectName) == ["alpha", "beta"])

        // Alpha's permission is granted and the tool runs: alpha goes quiet on its own.
        clock.advance(20)
        try fire(["hook_event_name": "PostToolUse", "session_id": "sess-alpha", "cwd": alpha.cwd, "tool_name": "Bash"], at: clock.now, identity: alpha)
        cycle(engine, now: clock.now)
        #expect(engine.visibleItems().map(\.identity.projectName) == ["beta"])
    }

    @Test("Claude Code's own sequence of notifications for one wait produces one card")
    func realNotificationSequenceCollapses() throws {
        let (engine, clock, _) = makeEngine()
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)

        // The sequence seen in practice: the tool asks, Claude Code prompts, then keeps prompting.
        try fire(["hook_event_name": "PermissionRequest", "session_id": "sess-alpha", "cwd": alpha.cwd, "tool_name": "Bash"],
                 at: clock.now, identity: alpha, override: .init(kind: .approval))
        clock.advance(6)
        try fire(["hook_event_name": "Notification", "session_id": "sess-alpha", "cwd": alpha.cwd,
                  "notification_type": "permission_prompt", "message": "Claude needs your permission"],
                 at: clock.now, identity: alpha, override: .init(kind: .approval))
        clock.advance(60)
        try fire(["hook_event_name": "Notification", "session_id": "sess-alpha", "cwd": alpha.cwd,
                  "notification_type": "idle_prompt", "message": "Claude is waiting for your input"],
                 at: clock.now, identity: alpha, override: .init(kind: .idle))

        let effects = cycle(engine, now: clock.now)
        #expect(effects.raisedItems.count == 1, "one wait, one alert")
        #expect(engine.allItems().count == 1)
        #expect(engine.allItems().first?.kind == .approval)
        #expect(engine.allItems().first?.detail == "Permission needed: Bash", "the tool name survives the vaguer prompts")
        #expect(engine.allItems().first?.occurrences == 3)
    }

    @Test("Explicit hook arguments classify without reading payload field names")
    func explicitArgumentsDriveClassification() throws {
        let (engine, clock, _) = makeEngine()
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)

        // A payload whose fields have all been renamed upstream. The matcher-supplied argument is
        // the whole contract.
        try fire(["hook_event_name": "Notification", "session_id": "sess-alpha", "cwd": alpha.cwd,
                  "kind_of_notification": "permission_prompt", "body": "something"],
                 at: clock.now, identity: alpha, override: .init(kind: .approval))

        cycle(engine, now: clock.now)
        #expect(engine.visibleItems().first?.kind == .approval)
    }

    @Test("The app recovers after being closed while hooks kept firing")
    func recoveryAcrossRestart() throws {
        let clock = TestClock(Fixture.origin)
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)

        let first = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        try fire(["hook_event_name": "Stop", "session_id": "sess-alpha", "cwd": alpha.cwd,
                  "background_tasks": [], "session_crons": []], at: clock.now, identity: alpha)
        cycle(first, now: clock.now)
        #expect(first.pendingCount == 1)

        // App quits. Hooks keep writing.
        clock.advance(30)
        try fire(["hook_event_name": "Notification", "session_id": "sess-alpha", "cwd": alpha.cwd,
                  "notification_type": "permission_prompt", "message": "Claude needs your permission"],
                 at: clock.now, identity: alpha, override: .init(kind: .approval))

        // App restarts.
        clock.advance(10)
        let second = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: store.loadSnapshot())
        #expect(second.pendingCount == 1, "the queue is restored before anything new is read")
        cycle(second, now: clock.now)

        #expect(second.allItems().count == 1, "still the same wait — the app restarting is not news")
        #expect(second.visibleItems().first?.occurrences == 2)
        // No work happened in between, so this is still one wait — but "needs approval" is a
        // sharper description of it than "finished", so the card upgrades rather than duplicating.
        #expect(second.visibleItems().first?.kind == .approval)
    }

    @Test("A crash between reading the spool and saving state loses no alert")
    func crashMidCycleLosesNothing() throws {
        let clock = TestClock(Fixture.origin)
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)
        try fire(["hook_event_name": "Notification", "session_id": "sess-alpha", "cwd": alpha.cwd,
                  "notification_type": "permission_prompt", "message": "Claude needs your permission"],
                 at: clock.now, identity: alpha, override: .init(kind: .approval))

        // A cycle that reads and ingests, then dies before saving. Nothing is acknowledged.
        let doomed = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        let drained = store.readSpool()
        doomed.ingest(drained.events)
        #expect(doomed.pendingCount == 1)

        // Fresh process, no saved state at all.
        let revived = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: store.loadSnapshot())
        cycle(revived, now: clock.now)
        #expect(revived.pendingCount == 1, "the spool file was still there, so the alert came back")
    }

    @Test("SessionEnd clears the heartbeat file too")
    func sessionEndCleansUpDisk() throws {
        let (engine, clock, _) = makeEngine()
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)

        try fire(["hook_event_name": "Stop", "session_id": "sess-alpha", "cwd": alpha.cwd,
                  "background_tasks": [], "session_crons": []], at: clock.now, identity: alpha)
        cycle(engine, now: clock.now)
        #expect(engine.pendingCount == 1)

        clock.advance(5)
        try fire(["hook_event_name": "SessionEnd", "session_id": "sess-alpha", "cwd": alpha.cwd, "reason": "logout"], at: clock.now, identity: alpha)

        for case let .sessionDropped(sessionID, _) in cycle(engine, now: clock.now) {
            store.removeHeartbeat(sessionID: sessionID)
        }

        #expect(engine.pendingCount == 0)
        #expect(store.readHeartbeats().isEmpty)
    }

    @Test("A session that ended while the app was closed does not linger on disk")
    func orphanHeartbeatIsPruned() throws {
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)
        try fire(["hook_event_name": "PostToolUse", "session_id": "sess-alpha", "cwd": alpha.cwd, "tool_name": "Read"],
                 at: Fixture.origin, identity: alpha)
        #expect(store.readHeartbeats().count == 1)

        let liveness = StubLiveness()
        liveness.kill(100)
        let (engine, clock, _) = makeEngine(liveness: liveness)
        cycle(engine, liveness: liveness, now: clock.now)

        #expect(store.readHeartbeats().isEmpty, "nothing else would ever clean this up")
        #expect(engine.sessions.isEmpty)
    }

    @Test("Emitted records carry no prompt, assistant or tool text")
    func noSensitiveTextOnDisk() throws {
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)
        try fire([
            "hook_event_name": "Stop",
            "session_id": "sess-alpha",
            "cwd": alpha.cwd,
            "prompt_text": "SECRET-PROMPT-CONTENT",
            "prompt": "SECRET-PROMPT-CONTENT",
            "last_assistant_message": "SECRET-ASSISTANT-CONTENT",
            "transcript_path": "/Users/dev/.claude/projects/x/transcript.jsonl",
            "tool_input": ["command": "echo SECRET-TOOL-INPUT"],
        ], at: Fixture.origin, identity: alpha)

        var written = ""
        for directory in [paths.spool, paths.sessions] {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".json") {
                written += try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            }
        }

        for secret in ["SECRET-PROMPT-CONTENT", "SECRET-ASSISTANT-CONTENT", "SECRET-TOOL-INPUT", "transcript.jsonl"] {
            #expect(!written.contains(secret), "\(secret) must never reach disk")
        }
        #expect(written.contains("sess-alpha"))
    }

    @Test("A hook message is only written down when the user has asked for it")
    func messageOptIn() throws {
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)
        let payload: [String: Any] = [
            "hook_event_name": "Notification", "session_id": "sess-alpha", "cwd": alpha.cwd,
            "notification_type": "permission_prompt", "message": "Claude needs your permission",
        ]

        try fire(payload, at: Fixture.origin, identity: alpha)
        var events = store.readSpool().events
        #expect(events.first?.detail == "Permission needed", "default: a static label, not the message")
        store.acknowledge(store.readSpool().receipts)

        var opted = AttentionConfig.default
        opted.includeHookMessages = true
        try fire(payload, at: Fixture.origin.addingTimeInterval(1), identity: alpha, config: opted)
        events = store.readSpool().events
        #expect(events.first?.detail == "Claude needs your permission")
    }

    @Test("Activity hooks leave no spool churn")
    func activityDoesNotSpool() throws {
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)
        for index in 0..<50 {
            try fire(
                ["hook_event_name": "PostToolUse", "session_id": "sess-alpha", "cwd": alpha.cwd, "tool_name": "Read"],
                at: Fixture.origin.addingTimeInterval(Double(index)),
                identity: alpha
            )
        }
        let spooled = try FileManager.default.contentsOfDirectory(atPath: paths.spool.path).filter { $0.hasSuffix(".json") }
        #expect(spooled.isEmpty, "ordinary work leaves no spool churn")
        #expect(store.readHeartbeats().count == 1)
    }

    @Test("A session that goes quiet for hours produces nothing through the whole pipeline")
    func silenceProducesNothing() throws {
        let (engine, clock, _) = makeEngine()
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)

        try fire(["hook_event_name": "PostToolUse", "session_id": "sess-alpha", "cwd": alpha.cwd, "tool_name": "Bash"], at: clock.now, identity: alpha)
        cycle(engine, now: clock.now)
        #expect(engine.pendingCount == 0)

        clock.advance(6 * 3600)
        #expect(cycle(engine, now: clock.now).raisedItems.isEmpty)
        #expect(engine.pendingCount == 0)
    }

    @Test("An ExitPlanMode call surfaces as a stage decision the user must make")
    func planApprovalReachesTheQueue() throws {
        let (engine, clock, _) = makeEngine()
        let alpha = Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)

        try fire(["hook_event_name": "PreToolUse", "session_id": "sess-alpha", "cwd": alpha.cwd, "tool_name": "ExitPlanMode"],
                 at: clock.now, identity: alpha, override: .init(kind: .stageDecision))
        cycle(engine, now: clock.now)

        #expect(engine.visibleItems().first?.kind == .stageDecision)
        #expect(engine.visibleItems().first?.source == .explicit)
    }
}
