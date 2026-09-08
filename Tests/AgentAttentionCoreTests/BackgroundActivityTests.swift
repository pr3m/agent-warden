import Foundation
import Testing
@testable import AgentAttentionCore

/// The three things kept apart: what the turn is doing, what it is asking for, and what is running
/// behind it.
@Suite("Background activity, parent and attention")
struct BackgroundActivityTests {
    private func stopPayload(tasks: [[String: Any]], crons: [[String: Any]]) -> [String: Any] {
        ["background_tasks": tasks, "session_crons": crons]
    }

    @Test("A Stop snapshot fills the session's job registry, not just a count")
    func snapshotPopulatesTheRegistry() {
        let (engine, clock, _) = makeEngine()
        let evidence = BackgroundEvidence.read(from: stopPayload(tasks: [
            ["id": "task-a", "type": "shell", "status": "running"],
            ["id": "task-b", "type": "monitor", "status": "running"],
        ], crons: []), now: clock.now)

        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .workComplete,
                                    at: clock.now, hookEvent: "Stop", background: evidence))

        let session = engine.sessions["s1"]
        #expect(session?.jobs.jobs.count == 2)
        #expect(session?.jobs.jobs.map(\.identity.taskID).sorted() == ["task-a", "task-b"])
        #expect(session?.jobs.jobs.allSatisfy { $0.identity.sessionID == "s1" } == true)
        #expect(session?.jobs.monitors == 1, "a monitor is not the same as a one-shot shell")
        #expect(session?.jobs.running == 2)
    }

    @Test("A session nobody has reported jobs for is not a session with no jobs")
    func anEmptyRegistryIsNotCompletion() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now))

        let session = engine.sessions["s1"]
        #expect(session?.jobs.jobs.isEmpty == true)
        #expect(session?.jobs.coverage == .unknown)
        #expect(session?.jobs.provesNothingIsRunning == false,
                "whole-goal completion can never be read off an empty registry")
    }

    @Test("An open approval survives a background job reporting progress")
    func aGenuineAskSurvivesChildProgress() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))
        #expect(engine.visibleItems(at: clock.now).count == 1)

        // A shell this session started reports progress. That is not the user's question being
        // answered, and it must not close the ask.
        var session = engine.sessions["s1"]!
        let frame = BackgroundLifecycleFrame(["type": "system", "subtype": "task_progress", "session_id": "s1",
                                              "task_id": "T1", "uuid": "e1"])!
        session.jobs.apply(frame, ownedBy: "s1", at: clock.now.addingTimeInterval(30))
        engine.replaceSessionForTesting(session)

        let items = engine.visibleItems(at: clock.now.addingTimeInterval(60))
        #expect(items.count == 1)
        #expect(items[0].kind == .approval, "only the parent resuming, or an answer, closes this")
    }

    @Test("A failed background job stays actionable while other jobs keep running")
    func aFailureAmongRunningJobsIsStillAFailure() {
        let (engine, clock, _) = makeEngine()
        let evidence = BackgroundEvidence.read(from: stopPayload(tasks: [
            ["id": "ok", "type": "shell", "status": "running"],
            ["id": "bad", "type": "shell", "status": "failed"],
        ], crons: []), now: clock.now)

        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .workComplete,
                                    at: clock.now, hookEvent: "Stop", background: evidence))

        #expect(engine.visibleItems(at: clock.now).contains { $0.kind == .error },
                "a running sibling does not make a failure quiet")
        let session = engine.sessions["s1"]
        #expect(session?.jobs.failed == 1)
        #expect(session?.jobs.running == 1)
    }

    @Test("A monitor running does not hide a question")
    func aMonitorDoesNotSuppressAnAsk() {
        let (engine, clock, _) = makeEngine()
        let evidence = BackgroundEvidence.read(from: stopPayload(tasks: [
            ["id": "mon", "type": "monitor", "status": "running"],
        ], crons: []), now: clock.now)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .workComplete,
                                    at: clock.now, hookEvent: "Stop", background: evidence))
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .question,
                                    detail: "Which option?", at: clock.now.addingTimeInterval(5)))

        let items = engine.visibleItems(at: clock.now.addingTimeInterval(10))
        #expect(items.contains { $0.kind == .question },
                "a long-lived monitor must not silence a real ask indefinitely")
    }
}

/// Whether a queued alert may still be played when it finally comes up.
@Suite("Alert dispatch recheck")
struct AlertDispatchTests {
    private func session(episode: String, activity: SessionActivityState = .awaitingUser,
                         at moment: Date) -> SessionState {
        SessionState(identity: Fixture.identity(session: "s1"), activity: activity,
                     lastEventAt: moment, lastActivityAt: moment, episodeID: episode)
    }

    private func item(kind: AttentionKind, episode: String, at moment: Date) -> AttentionItem {
        AttentionItem(sessionID: "s1", episodeID: episode, kind: kind, source: .explicit,
                      detail: "detail", firstSeenAt: moment, lastSeenAt: moment,
                      identity: Fixture.identity(session: "s1"))
    }

    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("An alert for the episode that is still open is dispatched")
    func aCurrentAlertStillPlays() {
        let state = session(episode: "E1", at: t0)
        #expect(AlertDispatch.shouldDispatch(item(kind: .approval, episode: "E1", at: t0),
                                             session: state, at: t0.addingTimeInterval(5)))
    }

    @Test("An alert whose episode has been superseded is dropped at dispatch")
    func aStaleEpisodeIsDropped() {
        // The session went back to work, which opens a new episode. The queued alert belongs to
        // the old one, and playing it would ask about something already resolved.
        let resumed = session(episode: "E2", activity: .working, at: t0.addingTimeInterval(30))
        #expect(!AlertDispatch.shouldDispatch(item(kind: .approval, episode: "E1", at: t0),
                                              session: resumed, at: t0.addingTimeInterval(31)))
    }

    @Test("A generic completion is cancelled once the session resumes work")
    func aDelayedCompletionIsCancelled() {
        let resumed = session(episode: "E1", activity: .working, at: t0.addingTimeInterval(20))
        #expect(!AlertDispatch.shouldDispatch(item(kind: .workComplete, episode: "E1", at: t0),
                                              session: resumed, at: t0.addingTimeInterval(21)),
                "‘it finished’ is not true any more once it carried on")
    }

    @Test("A genuine blocker is not cancelled by the session doing other things", arguments: [
        AttentionKind.approval, .question, .error, .handoff, .stageDecision,
    ])
    func aBlockerIsNotCancelledByProgress(_ kind: AttentionKind) {
        // Same episode, session busy: a child job's progress, or the parent working on something
        // else, does not answer a question that was put to the user.
        let busy = session(episode: "E1", activity: .working, at: t0.addingTimeInterval(20))
        #expect(AlertDispatch.shouldDispatch(item(kind: kind, episode: "E1", at: t0),
                                             session: busy, at: t0.addingTimeInterval(21)),
                "only an answer or an explicit resolution closes a real ask")
    }

    @Test("An alert for a session that has gone is dropped")
    func aVanishedSessionDropsTheAlert() {
        #expect(!AlertDispatch.shouldDispatch(item(kind: .approval, episode: "E1", at: t0),
                                              session: nil, at: t0))
    }

    @Test("A dismissed episode is not re-announced")
    func aDismissedEpisodeIsQuiet() {
        var state = session(episode: "E1", at: t0)
        state.episodeDismissed = true
        #expect(!AlertDispatch.shouldDispatch(item(kind: .approval, episode: "E1", at: t0),
                                              session: state, at: t0.addingTimeInterval(5)))
    }
}

/// The status report: a photograph from an hour ago is not a statement about now.
@Suite("Background reporting freshness")
struct BackgroundReportingTests {
    private func report(_ session: SessionState, now: Date) -> StatusReport.BackgroundSummary? {
        var config = AttentionConfig.default
        config.backgroundEvidenceTTLSeconds = 1_800
        return StatusReport.backgroundSummary(session, config: config, now: now)
    }

    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func session(evidence: BackgroundEvidence, superseded: Date? = nil) -> SessionState {
        var state = SessionState(identity: Fixture.identity(session: "s1"), activity: .awaitingUser,
                                 lastEventAt: t0, lastActivityAt: t0)
        state.background = evidence
        state.backgroundSupersededAt = superseded
        return state
    }

    @Test("A fresh, unsuperseded, empty reading is a confirmed completion")
    func freshCompletionIsConfirmed() {
        let evidence = BackgroundEvidence(availability: .none, observedAt: t0)
        #expect(report(session(evidence: evidence), now: t0.addingTimeInterval(60))?
            .confirmedComplete == true)
    }

    @Test("The same reading an hour later is not")
    func staleCompletionIsNotCurrentCertainty() {
        let evidence = BackgroundEvidence(availability: .none, observedAt: t0)
        let summary = report(session(evidence: evidence), now: t0.addingTimeInterval(3_600))
        #expect(summary?.confirmedComplete == false,
                "an observation from an hour ago cannot read as certainty about now")
        #expect(summary?.observationOnly == true, "and it is still shown, labelled for what it is")
    }

    @Test("A reading the session has already worked past is not a completion either")
    func supersededCompletionIsNotConfirmed() {
        let evidence = BackgroundEvidence(availability: .none, observedAt: t0)
        let summary = report(session(evidence: evidence, superseded: t0.addingTimeInterval(10)),
                             now: t0.addingTimeInterval(20))
        #expect(summary?.confirmedComplete == false)
        #expect(summary?.observationOnly == true)
    }

    @Test("Per-job detail is reported, with each job's own freshness")
    func jobsAreListedIndividually() {
        var state = session(evidence: BackgroundEvidence(availability: .reported, running: 1,
                                                          observedAt: t0))
        var registry = BackgroundRegistry()
        registry.apply(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started", "session_id": "s1",
                                                 "task_id": "T1", "uuid": "e1",
                                                 "task_type": "monitor"])!,
                       ownedBy: "s1", at: t0)
        state.jobs = registry

        let summary = report(state, now: t0.addingTimeInterval(60))
        #expect(summary?.jobs.count == 1)
        let job = summary?.jobs.first
        #expect(job?.taskID == "T1")
        #expect(job?.sessionID == "s1")
        #expect(job?.kind == "monitor")
        #expect(job?.state == "running")
        #expect(job?.source == "lifecycleStream")
        #expect(job?.ageSeconds == 60)
        #expect(job?.stale == false)
        #expect(summary?.coverage == "observed", "and never a claim that this is all of them")
    }
}
