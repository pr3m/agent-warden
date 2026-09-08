import Foundation
import Testing
@testable import AgentAttentionCore

/// A turn that ends while work continues behind it is *paused*, not finished.
///
/// The `Stop` hook documents `background_tasks` and `session_crons`, which is a structured answer to
/// a question this app could not otherwise ask without reading transcript text. The rule throughout:
/// only what the arrays actually say is claimed, an unrecognised status makes the reading uncertain,
/// and an explicit ask stays actionable whatever is running.
///
/// Observed on this machine, and the reason this exists: `red645-own-capital` started a background
/// Bash task at 08:27:55Z, ended its turn at 08:28:39Z still describing work in progress, and the
/// app announced "work complete".
@Suite("Background work")
struct BackgroundWaitTests {

    private func stop(
        session: String = "s1",
        tasks: [[String: Any]]? = nil,
        crons: [[String: Any]]? = nil,
        at moment: Date
    ) -> EmittedEvent {
        var payload: [String: Any] = ["hook_event_name": "Stop", "session_id": session, "cwd": "/Users/dev/code/alpha"]
        if let tasks { payload["background_tasks"] = tasks }
        if let crons { payload["session_crons"] = crons }
        let outcome = HookIngestion.process(
            payload: payload,
            identity: Fixture.identity(session: session),
            now: moment,
            config: .default,
            override: .init(kind: .workComplete)
        )
        return outcome.event!
    }

    private func task(_ status: String, type: String = "shell") -> [String: Any] {
        // `description` and `command` are in the real entries. Nothing here may end up persisted.
        ["id": "task-\(status)", "type": type, "status": status,
         "description": "SECRET-TASK-DESCRIPTION", "command": "SECRET-COMMAND"]
    }

    // MARK: - Reading the payload

    @Test("A running task is reported, and only counts are kept")
    func readsRunningTask() throws {
        let event = stop(tasks: [task("running")], crons: [], at: Fixture.origin)
        let evidence = try #require(event.background)

        #expect(evidence.availability == .reported)
        #expect(evidence.running == 1)
        #expect(evidence.types == ["shell"])
        #expect(evidence.isWaitingOnBackgroundWork)

        let encoded = try String(data: JSONCoding.encoder.encode(event), encoding: .utf8) ?? ""
        #expect(!encoded.contains("SECRET-TASK-DESCRIPTION"))
        #expect(!encoded.contains("SECRET-COMMAND"))
    }

    @Test("Empty arrays are a confirmed finish")
    func emptyArraysMeanDone() throws {
        let evidence = try #require(stop(tasks: [], crons: [], at: Fixture.origin).background)
        #expect(evidence.availability == .none)
        #expect(evidence.isConfirmedComplete)
        #expect(!evidence.isWaitingOnBackgroundWork)
    }

    @Test("Missing arrays are unknown, not empty")
    func missingArraysAreUnknown() throws {
        // An older Claude Code, or a payload we only scanned. Neither "busy" nor "finished".
        let evidence = try #require(stop(tasks: nil, at: Fixture.origin).background)
        #expect(evidence.availability == .unknown)
        #expect(!evidence.isConfirmedComplete)
        #expect(!evidence.isWaitingOnBackgroundWork)
    }

    @Test("A status we do not recognise makes the whole reading uncertain")
    func unknownStatusIsUncertain() throws {
        let evidence = try #require(stop(tasks: [task("running"), task("quiescing")], crons: [], at: Fixture.origin).background)
        #expect(evidence.availability == .unknown, "an unfamiliar vocabulary is not a confident answer")
        #expect(evidence.unrecognised == 1)
        #expect(!evidence.isWaitingOnBackgroundWork)
        #expect(!evidence.isConfirmedComplete)
    }

    @Test("Malformed entries do not throw the reading away, they make it uncertain")
    func malformedEntries() {
        let evidence = BackgroundEvidence.read(
            from: ["background_tasks": [["id": "x"], ["status": 42]], "session_crons": []],
            now: Fixture.origin)
        #expect(evidence.availability == .unknown)
        #expect(evidence.unrecognised == 2)
    }

    @Test("A task array of the wrong shape is unknown")
    func wrongShape() {
        #expect(BackgroundEvidence.read(from: ["background_tasks": "nope"], now: Fixture.origin).availability == .unknown)
        #expect(BackgroundEvidence.read(from: [:], now: Fixture.origin).availability == .unknown)
    }

    // MARK: - Scheduled wakeups, and the shape of the evidence

    @Test("A scheduled wakeup with no tasks is pending work, not a finished turn")
    func cronOnlyIsNotCompletion() throws {
        // `session_crons` are scheduled wakeups. An empty task list beside one of them means the
        // session is waiting for a clock, not that it has finished.
        let evidence = try #require(stop(
            tasks: [],
            crons: [["id": "wake-1", "schedule": "0 9 * * *", "recurring": true]],
            at: Fixture.origin
        ).background)

        #expect(evidence.availability == .reported)
        #expect(evidence.crons == 1)
        #expect(evidence.isWaitingOnBackgroundWork)
        #expect(!evidence.isConfirmedComplete, "a pending wakeup is not a completed turn")
        #expect(evidence.summaryLine.contains("scheduled"))
    }

    @Test("A missing cron array is a hole in the evidence, not an empty one")
    func missingCronsIsUnknown() throws {
        // The documented payload carries both arrays when the registry is reachable. If one is
        // absent we did not get a complete answer, and an incomplete answer cannot confirm a
        // completion — this is the exact shape that used to read as "Turn complete".
        let evidence = try #require(stop(tasks: [], crons: nil, at: Fixture.origin).background)
        #expect(evidence.availability == .unknown)
        #expect(!evidence.isConfirmedComplete, "tasks=[] with no cron list must not read as done")
        #expect(!evidence.isWaitingOnBackgroundWork)
    }

    @Test("A malformed cron array is uncertain too")
    func malformedCronsAreUncertain() {
        let payloads: [[String: Any]] = [
            ["background_tasks": [], "session_crons": "nope"],
            ["background_tasks": [], "session_crons": [[String: Any]()]],
            ["background_tasks": [], "session_crons": 7],
        ]
        for payload in payloads {
            let evidence = BackgroundEvidence.read(from: payload, now: Fixture.origin)
            #expect(evidence.availability == .unknown)
            #expect(!evidence.isConfirmedComplete)
        }
    }

    @Test("Running tasks and scheduled wakeups together are still one pause")
    func runningPlusCrons() throws {
        let evidence = try #require(stop(
            tasks: [task("running")],
            crons: [["id": "wake-1"], ["id": "wake-2"]],
            at: Fixture.origin
        ).background)
        #expect(evidence.availability == .reported)
        #expect(evidence.running == 1)
        #expect(evidence.crons == 2)
        #expect(evidence.isWaitingOnBackgroundWork)
        #expect(evidence.summaryLine.contains("2 scheduled"))
    }

    @Test("Mixed finished and running tasks are a pause, not a completion")
    func mixedStatuses() throws {
        let evidence = try #require(stop(
            tasks: [task("completed"), task("running"), task("queued")], crons: [], at: Fixture.origin
        ).background)
        #expect(evidence.availability == .reported)
        #expect(evidence.running == 2)
        #expect(evidence.completed == 1)
        #expect(!evidence.isConfirmedComplete)
    }

    // MARK: - Failure precedence

    @Test("A failure outranks everything else in the reading")
    func failurePrecedence() throws {
        // A task that failed while others carry on running must not be filed as a quiet pause.
        let evidence = try #require(stop(
            tasks: [task("failed"), task("running")], crons: [], at: Fixture.origin
        ).background)

        #expect(evidence.hasFailure)
        #expect(!evidence.isWaitingOnBackgroundWork, "an error is not something to hide behind a pause")
        #expect(!evidence.isConfirmedComplete, "and it is certainly not a success")
        #expect(evidence.summaryLine.contains("failed"))
        #expect(evidence.summaryLine.contains("still running"))
    }

    @Test("A failed task is raised as an error, never as a completed turn")
    func failureBecomesAnError() {
        let (engine, clock, _) = makeEngine()
        let effects = engine.ingest(stop(tasks: [task("failed"), task("running")], crons: [], at: clock.now))

        #expect(effects.raisedItems.count == 1)
        #expect(engine.visibleItems().first?.kind == .error, "a failure is not a success")
        #expect(engine.sessionsWaitingOnBackgroundWork(at: clock.now).isEmpty)
        #expect(engine.session("s1")?.activity == .awaitingUser)
    }

    @Test("A cron-only Stop is a quiet pause, with nothing in the queue")
    func cronOnlyIsQuiet() {
        let (engine, clock, _) = makeEngine()
        let effects = engine.ingest(stop(
            tasks: [], crons: [["id": "wake-1", "schedule": "0 9 * * *"]], at: clock.now))

        #expect(effects.raisedItems.isEmpty)
        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1")?.activity == .backgroundWaiting)
        #expect(engine.sessionsWaitingOnBackgroundWork(at: clock.now).count == 1)
    }

    // MARK: - What the queue does with it

    @Test("Stop with a task still running is a pause, not an alert")
    func stopWithRunningTaskDoesNotAlert() {
        let (engine, clock, _) = makeEngine()
        let effects = engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))

        #expect(effects.raisedItems.isEmpty, "the turn paused; it did not finish")
        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1")?.activity == .backgroundWaiting)
        #expect(engine.sessionsWaitingOnBackgroundWork(at: clock.now).count == 1)
    }

    @Test("Waiting on background work is not the same as working")
    func backgroundWaitIsItsOwnState() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))
        #expect(engine.sessions.values.contains { $0.activity == .working } == false)
        #expect(engine.pendingCount == 0)
    }

    @Test("Stop with nothing running is a confirmed completion and does alert")
    func stopWithNoTasksAlerts() {
        let (engine, clock, _) = makeEngine()
        let effects = engine.ingest(stop(tasks: [], crons: [], at: clock.now))

        #expect(effects.raisedItems.count == 1)
        #expect(engine.visibleItems().first?.kind == .workComplete)
        #expect(engine.visibleItems().first?.detail == "Turn complete")
    }

    @Test("Stop with unknown evidence is passive — it does not claim completion, and it does not alert")
    func stopWithUnknownEvidenceIsPassive() {
        let (engine, clock, _) = makeEngine()
        let effects = engine.ingest(stop(tasks: nil, at: clock.now))

        // Uncertainty is not a request. It gets no card, no badge, no sound — the row simply says
        // it does not know. Raising a "completion not confirmed" card would still be an alert
        // about something nobody asked for.
        #expect(effects.raisedItems.isEmpty)
        #expect(engine.pendingCount == 0)
        #expect(engine.allItems().isEmpty)
        #expect(engine.session("s1")?.activity == .unknown, "not 'waiting at the prompt' — unknown")
        #expect(engine.session("s1")?.background?.availability == .unknown)
    }

    @Test("A generic completion with no structured evidence at all is passive too")
    func genericCompletionWithoutEvidence() {
        // `Notification/agent_completed` carries no task arrays. It cannot confirm anything, so it
        // must not become an alert by virtue of being a different hook.
        let (engine, clock, _) = makeEngine()
        let effects = engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .workComplete,
                                                  at: clock.now, hookEvent: "Notification"))
        #expect(effects.raisedItems.isEmpty)
        #expect(engine.pendingCount == 0)
    }

    @Test("An idle prompt on its own is a state, not a request")
    func idleAloneIsPassive() {
        let (engine, clock, _) = makeEngine()
        let effects = engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .idle,
                                                  at: clock.now, hookEvent: "Notification"))
        #expect(effects.raisedItems.isEmpty)
        #expect(engine.pendingCount == 0)
    }

    @Test("A completed-with-failures turn stays actionable and names the failure")
    func failedTasksStayActionable() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [task("completed"), task("failed")], crons: [], at: clock.now))

        #expect(engine.pendingCount == 1, "a failure is not something to hide behind a pause")
        #expect(engine.visibleItems().first?.kind == .error)
        #expect(engine.visibleItems().first?.detail.contains("failed") == true)
    }

    // MARK: - Withdrawing a claim we can no longer stand behind

    @Test("A completion card is withdrawn when a later Stop says work is still running")
    func completionWithdrawnByLaterBackgroundWork() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [], crons: [], at: clock.now))
        #expect(engine.pendingCount == 1, "confirmed complete, so it is shown")

        clock.advance(30)
        let effects = engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))

        #expect(engine.pendingCount == 0, "the newer evidence contradicts the card; the card goes")
        #expect(engine.allItems().isEmpty)
        #expect(effects.contains { if case .resolved(_, .evidenceWithdrawn) = $0 { return true } else { return false } })
        #expect(engine.session("s1")?.activity == .backgroundWaiting)
    }

    @Test("A real ask is never withdrawn by a later background Stop")
    func askSurvivesLaterBackgroundWork() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))
        #expect(engine.pendingCount == 1)

        clock.advance(30)
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))

        #expect(engine.pendingCount == 1, "you are still being asked for something")
        #expect(engine.visibleItems().first?.kind == .approval)
        #expect(engine.session("s1")?.activity == .awaitingUser,
                "the request is the session's state; the background work is secondary")
        #expect(engine.sessionsWaitingOnBackgroundWork(at: clock.now).isEmpty,
                "and it is not counted as a quiet pause while it is asking")
    }

    @Test("A snoozed ask survives a later background Stop, snooze intact")
    func snoozedAskSurvivesLaterBackgroundWork() throws {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, at: clock.now))
        let itemID = try #require(engine.visibleItems().first?.id)
        engine.snooze(itemID: itemID, for: 600)
        #expect(engine.pendingCount == 0, "snoozed, so not visible")

        clock.advance(30)
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))

        #expect(engine.allItems().count == 1, "the ask is still there, just quiet")
        #expect(engine.allItems().first?.snoozedUntil != nil, "and it is still snoozed")
        #expect(engine.session("s1")?.activity == .awaitingUser)
    }

    @Test("Real work after a background pause is working, not paused")
    func activityEndsThePause() {
        // The pause is a fact about a moment. Once the session does something, it is working —
        // even though the task snapshot is still on the record and nothing has told us the task
        // finished.
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))
        #expect(engine.sessionsWaitingOnBackgroundWork(at: clock.now).count == 1)

        clock.advance(20)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "UserPromptSubmit"))

        #expect(engine.session("s1")?.activity == .working)
        #expect(engine.sessionsWaitingOnBackgroundWork(at: clock.now).isEmpty, "it is working, not paused")
        #expect(engine.session("s1")?.background?.running == 1,
                "the reading is kept — we were never told the task finished")
        #expect(engine.session("s1")?.background?.isConfirmedComplete == false,
                "and it must not be rewritten into a completion to make the count tidy")
    }

    @Test("Once the pause ages out, a later idle prompt still cannot raise anything")
    func expiredPauseIsNotAnOpening() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))

        clock.advance(AttentionConfig.default.backgroundEvidenceTTLSeconds + 120)
        engine.sweep()
        #expect(engine.session("s1")?.activity == .unknown, "stale evidence is uncertainty, not a pause")

        let effects = engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .idle, at: clock.now))
        #expect(effects.raisedItems.isEmpty, "an expired reading is not permission to start alerting")
        #expect(engine.pendingCount == 0)
    }

    @Test("An explicit ask is actionable even while background work runs")
    func askDuringBackgroundWorkStillAlerts() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))
        #expect(engine.pendingCount == 0)

        clock.advance(30)
        let effects = engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                                  detail: "Permission needed: Bash", at: clock.now))
        #expect(effects.raisedItems.count == 1, "being busy is not a reason to sit on a permission prompt")
        #expect(engine.visibleItems().first?.kind == .approval)
        #expect(engine.session("s1")?.activity == .awaitingUser)
    }

    @Test("A question during background work is actionable too", arguments: [
        AttentionKind.question, .stageDecision, .error,
    ])
    func explicitKindsSurviveBackgroundWork(kind: AttentionKind) {
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))
        clock.advance(10)
        #expect(engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: kind, at: clock.now))
            .raisedItems.count == 1)
    }

    @Test("A generic idle notification does not undo the background reading")
    func idleDoesNotOverrideBackgroundEvidence() {
        // Claude Code emits its own idle prompt a minute after a turn ends. That is a generic
        // status, not new information about the tasks.
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))

        clock.advance(60)
        let effects = engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .idle,
                                                  at: clock.now, hookEvent: "Notification"))
        #expect(effects.raisedItems.isEmpty)
        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1")?.activity == .backgroundWaiting)
    }

    @Test("Real work supersedes the pause without discarding the reading")
    func activitySupersedesTheWait() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))

        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        #expect(engine.session("s1")?.activity == .working)
        #expect(engine.session("s1")?.background?.running == 1, "tasks outlive the turn that started them")
    }

    @Test("Stale evidence stops counting as a pause")
    func staleEvidenceExpires() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))
        #expect(engine.sessionsWaitingOnBackgroundWork(at: clock.now).count == 1)

        clock.advance(AttentionConfig.default.backgroundEvidenceTTLSeconds + 60)
        #expect(engine.sessionsWaitingOnBackgroundWork(at: clock.now).isEmpty,
                "a reading from an hour ago is not a claim about now")
    }

    @Test("A repeated Stop does not stack up")
    func duplicateStopsCollapse() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [], crons: [], at: clock.now))
        #expect(engine.pendingCount == 1)

        clock.advance(5)
        engine.ingest(stop(tasks: [], crons: [], at: clock.now))
        #expect(engine.allItems().count == 1, "one wait, one card")
        #expect(engine.allItems().first?.occurrences == 2)
    }

    @Test("A late Stop that predates the session's last work is ignored")
    func lateStopIsIgnored() {
        let (engine, clock, _) = makeEngine()
        clock.advance(100)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))

        // Delivered out of order, from before that work happened.
        let effects = engine.ingest(stop(tasks: [], crons: [], at: clock.now.addingTimeInterval(-50)))
        #expect(effects.raisedItems.isEmpty)
        #expect(engine.pendingCount == 0)
    }

    @Test("A background pause survives a save and restore")
    func evidenceRoundTrips() throws {
        let (engine, clock, _) = makeEngine()
        engine.ingest(stop(tasks: [task("running")], crons: [], at: clock.now))

        let data = try JSONCoding.encoder.encode(engine.snapshot())
        let restored = try JSONCoding.decoder.decode(EngineSnapshot.self, from: data)
        let revived = AttentionEngine(config: .default, clock: TestClock(clock.now),
                                      liveness: StubLiveness(), restoring: restored)

        #expect(revived.session("s1")?.activity == .backgroundWaiting)
        #expect(revived.sessionsWaitingOnBackgroundWork(at: clock.now).count == 1)
    }

    @Test("A snapshot written before background evidence existed still loads")
    func oldSnapshotWithoutEvidence() throws {
        let json = """
        {"version":2,"savedAt":"2026-09-06T00:00:00.000+00:00","items":[],"recentEventIDs":[],
         "sessions":{"s1":{"identity":{"sessionID":"s1","cwd":"/x"},"activity":"awaitingUser",
         "lastEventAt":"2026-09-06T00:00:00.000+00:00","lastActivityAt":"2026-09-06T00:00:00.000+00:00",
         "episodeID":"ep-1","episodeDismissed":false}}}
        """
        let snapshot = try JSONCoding.decoder.decode(EngineSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.sessions["s1"]?.background == nil)
        #expect(snapshot.sessions["s1"]?.activity == .awaitingUser)
    }
}
