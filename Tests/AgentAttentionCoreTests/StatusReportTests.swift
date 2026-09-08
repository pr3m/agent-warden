import Foundation
import Testing
@testable import AgentAttentionCore

/// The read-only query interface. Its whole job is to be safe to ask and honest about how much the
/// answer can be trusted.
@Suite("Status report")
final class StatusReportTests {
    private let paths: AppPaths
    private let store: EventStore

    init() throws {
        paths = try Fixture.temporaryPaths()
        store = EventStore(paths: paths)
    }

    deinit {
        try? FileManager.default.removeItem(at: paths.root)
    }

    private func seedQueue(clock: TestClock = TestClock(Fixture.origin)) throws -> AttentionEngine {
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "sess-alpha", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now,
                                    identity: Fixture.identity(session: "sess-alpha", project: "alpha", pid: 100)))
        engine.ingest(Fixture.turnComplete(session: "sess-beta", at: clock.now,
                                           identity: Fixture.identity(session: "sess-beta", project: "beta", pid: 200)))
        try store.save(snapshot: engine.snapshot())
        return engine
    }

    @Test("Asking never changes anything")
    func queryingIsReadOnly() throws {
        _ = try seedQueue()
        try store.write(event: Fixture.event(session: "sess-gamma", signal: .attention, kind: .idle, at: Fixture.origin))
        let before = try FileManager.default.contentsOfDirectory(atPath: paths.spool.path)
        let stateBefore = try Data(contentsOf: paths.stateFile)

        _ = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Fixture.origin)
        _ = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Fixture.origin)

        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.spool.path) == before,
                "querying must not consume the spool")
        #expect(try Data(contentsOf: paths.stateFile) == stateBefore)
    }

    @Test("An empty queue with no app running is not reported as 'nothing to do'")
    func absentAppIsDistinguishedFromEmptyQueue() {
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Fixture.origin)
        #expect(report.counts.pending == 0)
        #expect(report.app.running == false)
        #expect(report.app.fresh == false)
        #expect(report.warnings.contains { $0.contains("not running") })
    }

    @Test("A running app with recent state is reported as fresh")
    func runningAndFresh() throws {
        _ = try seedQueue()
        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.2.0", startedAt: Fixture.origin))

        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.app.running == true)
        #expect(report.app.livenessVerified)
        #expect(report.app.pid == 4242)
        #expect(report.app.fresh, "state.json was written moments ago")
        #expect(report.counts.pending == 2)
        #expect(report.warnings.isEmpty)
    }

    @Test("A running app whose state has gone quiet is reported as stale")
    func runningButStale() throws {
        _ = try seedQueue()
        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.2.0", startedAt: Fixture.origin))

        // Look at it from far in the future: the file on disk has not moved.
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(),
                                        now: Date().addingTimeInterval(3600))
        #expect(report.app.running == true)
        #expect(report.app.fresh == false)
        #expect((report.app.stateAgeSeconds ?? 0) > 60)
        #expect(report.warnings.contains { $0.contains("stale") })
    }

    @Test("A dead app process is not reported as running just because its file is there")
    func staleAppFile() throws {
        _ = try seedQueue()
        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.2.0", startedAt: Fixture.origin))
        let liveness = StubLiveness()
        liveness.kill(4242)

        let report = StatusReport.build(store: store, config: .default, liveness: liveness, now: Date())
        #expect(report.app.running == false)
        #expect(report.app.pid == nil)
    }

    @Test("Unprocessed hook events are counted and explained")
    func unprocessedEvents() throws {
        _ = try seedQueue()
        try store.write(event: Fixture.event(session: "sess-gamma", signal: .attention, kind: .idle, at: Fixture.origin))

        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.app.unprocessedEvents == 1)
        #expect(report.warnings.contains { $0.contains("waiting to be processed") })
    }

    @Test("Entries carry what an assistant needs to answer without a screenshot")
    func entryContents() throws {
        _ = try seedQueue()
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Fixture.origin.addingTimeInterval(125))

        let first = try #require(report.pending.first)
        #expect(first.kind == "approval")
        #expect(first.source == "reported")
        #expect(first.project == "alpha")
        #expect(first.reason == "Permission needed: Bash")
        #expect(first.waitingSeconds == 125)
        #expect(first.clickTarget == "appOnly")
        #expect(first.process == "alive")
        #expect(report.pending.map(\.kind) == ["approval", "workComplete"], "most blocking first")
    }

    @Test("Nothing inferred from silence ever reaches the status interface")
    func noInferredEntries() throws {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        clock.advance(12 * 3600)
        engine.sweep()
        try store.save(snapshot: engine.snapshot())

        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.pending.allSatisfy { $0.source == "reported" })
        #expect(report.pending.isEmpty)
    }

    @Test("A session whose process died is flagged rather than silently listed")
    func deadSessionIsFlagged() throws {
        _ = try seedQueue()
        let liveness = StubLiveness()
        liveness.kill(100)

        let report = StatusReport.build(store: store, config: .default, liveness: liveness, now: Date())
        #expect(report.pending.first?.process == "dead")
        #expect(report.warnings.contains { $0.contains("process is gone") })
    }

    @Test("Snoozed items are listed separately, not counted as waiting")
    func snoozedAreSeparate() throws {
        let clock = TestClock(Fixture.origin)
        let engine = try seedQueue(clock: clock)
        engine.snooze(itemID: engine.visibleItems()[0].id, for: 600)
        try store.save(snapshot: engine.snapshot())

        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: clock.now)
        #expect(report.counts.pending == 1)
        #expect(report.counts.snoozed == 1)
        #expect(report.snoozed.first?.snoozedUntil != nil)
    }

    @Test("The JSON is valid, self-describing and free of session content")
    func jsonShape() throws {
        _ = try seedQueue()
        let json = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date()).jsonString()
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        #expect(parsed["schema"] as? Int == StatusReport.currentSchema)
        for key in ["app", "counts", "pending", "snoozed", "sessions", "warnings", "generatedAt"] {
            #expect(parsed[key] != nil, "missing \(key)")
        }
        let app = try #require(parsed["app"] as? [String: Any])
        for key in ["running", "fresh", "unprocessedEvents"] {
            #expect(app[key] != nil, "missing app.\(key)")
        }
        #expect(!json.contains("\\/"), "paths should be readable")
    }

    @Test("The text summary says what it does and does not know")
    func textSummary() throws {
        _ = try seedQueue()
        let absent = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date()).textSummary()
        #expect(absent.contains("NOT RUNNING"))
        #expect(absent.contains("alpha"))

        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.2.0", startedAt: Fixture.origin))
        let live = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date()).textSummary()
        #expect(live.contains("live"))
        #expect(live.contains("waiting: 2"))
    }

    @Test("An empty but live queue says so plainly")
    func emptyLiveQueue() throws {
        let engine = AttentionEngine(config: .default, clock: TestClock(Fixture.origin), liveness: StubLiveness(), restoring: nil)
        try store.save(snapshot: engine.snapshot())
        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.2.0", startedAt: Fixture.origin))

        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.app.fresh)
        #expect(report.counts.pending == 0)
        #expect(report.warnings.isEmpty)
        #expect(report.textSummary().contains("nothing is waiting for you"))
    }

    @Test("A missing state file is reported, not silently shown as an empty queue")
    func noStateYet() {
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.warnings.contains { $0.contains("No saved queue") })
    }

    @Test("A refused process inspection is reported as unknown, never as dead")
    func deniedInspection() throws {
        _ = try seedQueue()
        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.3.0", startedAt: Fixture.origin))

        let sandboxed = StubLiveness()
        sandboxed.denyAll()
        let report = StatusReport.build(store: store, config: .default, liveness: sandboxed, now: Date())

        #expect(report.app.running == nil, "null, not false — we were not allowed to look")
        #expect(report.app.livenessVerified == false)
        #expect(report.app.presence == "unknown")
        #expect(report.app.fresh == false)
        #expect(report.warnings.contains { $0.contains("Process inspection is unavailable") })
        #expect(report.pending.allSatisfy { $0.process == "unknown" })
        #expect(report.warnings.allSatisfy { !$0.contains("process is gone") },
                "an inaccessible process must not be described as gone")
        #expect(report.answerIsTrustworthy == false)
        #expect(report.textSummary().contains("UNKNOWN"))
    }

    @Test("Querying under a denied sandbox still writes nothing")
    func deniedInspectionMutatesNothing() throws {
        _ = try seedQueue()
        try store.write(event: Fixture.event(session: "sess-gamma", signal: .attention, kind: .idle, at: Fixture.origin))
        let before = try FileManager.default.contentsOfDirectory(atPath: paths.spool.path).sorted()
        let stateBefore = try Data(contentsOf: paths.stateFile)

        let sandboxed = StubLiveness()
        sandboxed.denyAll()
        _ = StatusReport.build(store: store, config: .default, liveness: sandboxed, now: Date())

        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.spool.path).sorted() == before)
        #expect(try Data(contentsOf: paths.stateFile) == stateBefore)
        #expect(FileManager.default.fileExists(atPath: paths.appStatusFile.path) == false)
    }

    @Test("A session whose process cannot be inspected is unknown, not dead")
    func deniedSessionProcess() throws {
        _ = try seedQueue()
        let partial = StubLiveness()
        partial.deny(100)
        partial.kill(200)

        let report = StatusReport.build(store: store, config: .default, liveness: partial, now: Date())
        #expect(report.pending.first(where: { $0.project == "alpha" })?.process == "unknown")
        #expect(report.pending.first(where: { $0.project == "beta" })?.process == "dead")
    }

    @Test("A recent but unreadable state file is not fresh")
    func unreadableStateIsNotFresh() throws {
        try Data("{{{ not json".utf8).write(to: paths.stateFile)
        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.3.0", startedAt: Fixture.origin))

        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.app.running == true)
        #expect(report.app.stateReadable == false)
        #expect(report.app.fresh == false, "a recent mtime on a broken file is not freshness")
        #expect(report.counts.pending == 0)
        #expect(report.warnings.contains { $0.contains("could not be read") })
        #expect(report.answerIsTrustworthy == false)
    }

    @Test("Machine JSON carries the full session id, and a separate short one for display")
    func fullSessionIdsInJSON() throws {
        _ = try seedQueue()
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        let entry = try #require(report.pending.first)

        #expect(entry.sessionID == "sess-alpha", "short ids collide; machines get the stable one")
        #expect(entry.displayID == "sess-alp")
        #expect(report.sessions.allSatisfy { !$0.sessionID.isEmpty && $0.sessionID.count >= $0.displayID.count })
        #expect(report.jsonString().contains("\"sessionID\" : \"sess-alpha\""))
    }

    @Test("Every entry states what its Open button will actually do")
    func entriesCarryTheirOpenLabel() throws {
        _ = try seedQueue()
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.pending.allSatisfy { !$0.openLabel.isEmpty })
        #expect(report.pending.allSatisfy { $0.openLabel != "Open session" },
                "never promise a session jump we cannot make")
        #expect(report.pending.first?.openLabel == "Open Ghostty")
    }

    @Test("Trustworthiness gates the quiet answer")
    func trustworthyGate() throws {
        // Live, readable, recent, nothing pending: a script may act on the silence.
        let engine = AttentionEngine(config: .default, clock: TestClock(Fixture.origin), liveness: StubLiveness(), restoring: nil)
        try store.save(snapshot: engine.snapshot())
        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.3.0", startedAt: Fixture.origin))
        #expect(StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date()).answerIsTrustworthy)

        // App gone: the same empty queue means nothing.
        store.clearAppStatus()
        #expect(StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date()).answerIsTrustworthy == false)
    }

    // MARK: - Background work

    /// One `Stop` carrying a still-running task, saved as the app would save it.
    private func seedBackground(tasks: [[String: Any]]?, at moment: Date) throws {
        let engine = AttentionEngine(config: .default, clock: TestClock(moment), liveness: StubLiveness(), restoring: nil)
        var payload: [String: Any] = ["hook_event_name": "Stop", "session_id": "sess-bg", "cwd": "/Users/dev/code/alpha"]
        if let tasks {
            payload["background_tasks"] = tasks
            payload["session_crons"] = []
        }
        let outcome = HookIngestion.process(
            payload: payload,
            identity: Fixture.identity(session: "sess-bg", project: "alpha", pid: 100),
            now: moment,
            config: .default,
            override: .init(kind: .workComplete)
        )
        engine.ingest(outcome.event!)
        try store.save(snapshot: engine.snapshot())
        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.5.0", startedAt: moment))
    }

    private func task(_ status: String) -> [String: Any] {
        ["id": "t1", "type": "shell", "status": status,
         "description": "SECRET-TASK-DESCRIPTION", "command": "SECRET-COMMAND"]
    }

    @Test("A session paused on background work is reported, and never as attention")
    func backgroundWaitIsReportedApart() throws {
        let now = Date()
        try seedBackground(tasks: [task("running")], at: now)
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: now)

        #expect(report.counts.pending == 0, "nothing is being asked of the user")
        #expect(report.counts.sessionsWaitingOnBackground == 1)
        let background = try #require(report.sessions.first?.background)
        #expect(background.availability == "reported")
        #expect(background.running == 1)
        #expect(background.waiting)
        #expect(background.confirmedComplete == false)
        #expect(background.types == ["shell"])
    }

    @Test("No task text ever reaches the report")
    func noTaskContentLeaks() throws {
        let now = Date()
        try seedBackground(tasks: [task("running")], at: now)
        let json = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: now).jsonString()
        #expect(!json.contains("SECRET-TASK-DESCRIPTION"))
        #expect(!json.contains("SECRET-COMMAND"))
    }

    @Test("Missing task evidence reads as unknown, not as finished")
    func missingEvidenceIsUnknown() throws {
        let now = Date()
        try seedBackground(tasks: nil, at: now)
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: now)
        let background = try #require(report.sessions.first?.background)

        #expect(background.availability == "unknown")
        #expect(background.waiting == false)
        #expect(background.confirmedComplete == false)
        #expect(report.counts.sessionsWaitingOnBackground == 0)
    }

    @Test("A stale reading stops being a claim about now")
    func staleReadingIsNotACurrentClaim() throws {
        let observed = Date().addingTimeInterval(-(AttentionConfig.default.backgroundEvidenceTTLSeconds + 300))
        try seedBackground(tasks: [task("running")], at: observed)
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        let background = try #require(report.sessions.first?.background)

        #expect(background.waiting == false)
        #expect(background.summary.contains("stale"))
        #expect(report.counts.sessionsWaitingOnBackground == 0)
    }

    @Test("A live app with an uncertain session is not reported as all quiet")
    func uncertaintyIsNotTrustworthySilence() throws {
        // Deliberately with a fresh, running app snapshot: "app not running" would otherwise mask
        // the thing under test, which is that *having heard from a session* does not make its
        // current state known.
        let now = Date()
        try seedBackground(tasks: nil, at: now)

        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: now)
        #expect(report.app.running == true)
        #expect(report.app.fresh, "the queue is live and freshly written")
        #expect(report.counts.pending == 0)

        let session = try #require(report.sessions.first)
        #expect(session.hookCoverage, "a hook did report for it")
        #expect(session.attention == "uncertain", "but that says nothing about whether it needs you now")
        #expect(report.counts.sessionsUncertain == 1)
        #expect(!report.answerIsTrustworthy, "pending: 0 is not the whole answer here")
        #expect(report.warnings.contains { $0.contains("without anything confirming") })
    }

    @Test("A session paused on background work is positively not asking")
    func pausedSessionIsCertainlyQuiet() throws {
        let now = Date()
        try seedBackground(tasks: [task("running")], at: now)
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: now)

        #expect(report.sessions.first?.attention == "none", "we know exactly what it is doing")
        #expect(report.counts.sessionsUncertain == 0)
        #expect(report.answerIsTrustworthy)
    }

    @Test("A pause whose evidence has aged out goes back to uncertain")
    func stalePauseIsUncertain() throws {
        let observed = Date().addingTimeInterval(-(AttentionConfig.default.backgroundEvidenceTTLSeconds + 300))
        try seedBackground(tasks: [task("running")], at: observed)
        // The app's own presence has to be current, or the staleness of the app would mask this.
        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.6.0", startedAt: Date()))

        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.sessions.first?.attention == "uncertain")
        #expect(report.counts.sessionsWaitingOnBackground == 0)
        #expect(!report.answerIsTrustworthy)
    }

    @Test("The text summary separates background work from attention")
    func textSummarySeparatesThem() throws {
        let now = Date()
        try seedBackground(tasks: [task("running")], at: now)
        let text = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: now).textSummary()

        #expect(text.contains("on background work"))
        #expect(text.contains("waiting: 0"))
    }
}

/// Discovered sessions in the read-only interface.
///
/// The whole point of surfacing them is that a caller can tell "we have not heard from this
/// session" apart from "this session is quiet". The JSON has to carry that difference explicitly.
@Suite("Status: discovered sessions")
final class StatusDiscoveryTests {
    private let paths: AppPaths
    private let store: EventStore

    init() throws {
        paths = try Fixture.temporaryPaths()
        store = EventStore(paths: paths)
    }

    deinit {
        try? FileManager.default.removeItem(at: paths.root)
    }

    private func seed(clock: TestClock = TestClock(Fixture.origin)) throws -> AttentionEngine {
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        // One session we have heard from, one we have only found.
        engine.ingest(Fixture.event(session: "hooked", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse",
                                    identity: Fixture.identity(session: "hooked", project: "alpha", pid: 100)))
        let record = RegistryRecord(sessionID: "found", pid: 200,
                                    procStart: clock.now.addingTimeInterval(-3600),
                                    cwd: "/Users/dev/code/beta", title: "beta work",
                                    version: "2.1.261", status: "busy",
                                    startedAt: clock.now.addingTimeInterval(-3600), updatedAt: clock.now)
        engine.apply(discovery: DiscoveryReport(
            scannedAt: clock.now, registryPresent: true, inspectionAvailable: true,
            filesConsidered: 1, malformed: 0, oversized: 0,
            verified: [DiscoveredSession(record: record, identity: record.sessionIdentity())],
            rejected: []
        ), at: clock.now)
        try store.save(snapshot: engine.snapshot())
        return engine
    }

    @Test("A discovered session is listed, flagged, and not counted as working")
    func discoveredSessionIsFlagged() throws {
        _ = try seed()
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())

        #expect(report.counts.sessionsTracked == 2)
        #expect(report.counts.sessionsWorking == 1, "only the hook-covered one is confirmed working")
        #expect(report.counts.sessionsAwaitingFirstHook == 1)

        let found = try #require(report.sessions.first { $0.sessionID == "found" })
        #expect(found.hookCoverage == false)
        #expect(found.attention == "awaitingFirstHook")
        #expect(found.state == "discovered")
        #expect(found.title == "beta work")
        #expect(found.registryStatus == "busy", "carried verbatim, never interpreted")

        let hooked = try #require(report.sessions.first { $0.sessionID == "hooked" })
        #expect(hooked.hookCoverage, "a hook has reported for it")
        #expect(hooked.attention == "none",
                "and separately: it is working, so we positively know it is not asking for anything")
    }

    @Test("Silence from a discovered session is called out, not passed off as quiet")
    func warningExplainsTheGap() throws {
        _ = try seed()
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.counts.pending == 0)
        #expect(report.warnings.contains { $0.contains("not yet reported through a hook") })
        #expect(report.answerIsTrustworthy == false, "an empty queue is not the whole story here")
        #expect(report.textSummary().contains("awaiting first hook"))
    }

    @Test("Discovery freshness is reported separately from queue freshness")
    func discoveryFreshnessIsSeparate() throws {
        _ = try seed()
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.discovery.lastScanAt != nil)
        #expect(report.discovery.sessionsAwaitingFirstHook == 1)
        #expect(report.discovery.sessionsWithHookCoverage == 1)
        // Without a live scan handed in, the registry-wide facts are honestly absent.
        #expect(report.discovery.registryPresent == nil)
        #expect(report.discovery.verified == nil)
    }

    @Test("A live scan adds the registry-wide counts")
    func liveScanAddsCounts() throws {
        _ = try seed()
        let scan = DiscoveryReport(scannedAt: Date(), registryPresent: true, inspectionAvailable: true,
                                   filesConsidered: 6, malformed: 1, oversized: 0,
                                   verified: [], rejected: [RejectedRecord(sessionID: "x", pid: 1, verdict: .processGone)])
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(),
                                        discovery: scan, now: Date())
        #expect(report.discovery.registryPresent == true)
        #expect(report.discovery.processInspectionAvailable == true)
        #expect(report.discovery.verified == 0)
        #expect(report.discovery.rejected == 1)
        #expect(report.discovery.malformed == 1)
    }

    @Test("The JSON says schema 3 and carries the new fields")
    func jsonShape() throws {
        _ = try seed()
        let json = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date()).jsonString()
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(parsed["schema"] as? Int == 3)
        #expect(parsed["discovery"] != nil)
        let counts = try #require(parsed["counts"] as? [String: Any])
        #expect(counts["sessionsAwaitingFirstHook"] != nil)
    }

    @Test("Nothing from the registry ever becomes a pending item")
    func discoveryNeverCreatesWork() throws {
        _ = try seed()
        let report = StatusReport.build(store: store, config: .default, liveness: StubLiveness(), now: Date())
        #expect(report.pending.isEmpty)
        #expect(report.snoozed.isEmpty)
    }
}
