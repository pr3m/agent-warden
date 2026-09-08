import Foundation
import Testing
@testable import AgentAttentionCore

/// A handoff that asks the user to try something is an acceptance checkpoint. Nothing the agent
/// does afterwards can satisfy it.
@Suite("User acceptance handoffs")
struct UserAcceptanceTests {
    private func footer(_ request: String) -> String {
        "Did the work.\n\n**I need from you:** \(request)"
    }

    @Test("A declarative hand-back is an ask, question mark or not", arguments: [
        "UAT steps are here — please run through them.",
        "Please test the new flow and tell me if it behaves.",
        "Review the changed screens and confirm they look right.",
        "Try it on your machine and let me know.",
        "Ready for your acceptance testing.",
        "Have a look and confirm before I carry on.",
    ])
    func declarativeHandoffsAsk(_ request: String) {
        let reading = FinalHandoff.read(footer(request))
        #expect(reading.asksForSomething, "a request does not need a ‘?’ to be a request")
        #expect(reading.awaitsUserAcceptance,
                "this asks the user to try something; only the user can close it")
    }

    @Test("An ordinary decision request is an ask, but not an acceptance checkpoint")
    func ordinaryAsksAreNotAcceptance() {
        let reading = FinalHandoff.read(footer("Which database should this write to?"))
        #expect(reading.asksForSomething)
        #expect(!reading.awaitsUserAcceptance,
                "answering a question is not the same as accepting delivered work")
    }

    @Test("Work already tested is a report, not a checkpoint", arguments: [
        "I ran the UAT steps and they passed.",
        "UAT was completed last week.",
        "We already reviewed this together.",
        "Testing has been done; nothing outstanding.",
    ])
    func historyIsNotAnAsk(_ request: String) {
        let reading = FinalHandoff.read(footer(request))
        #expect(!reading.awaitsUserAcceptance, "a past tense is not a current handoff")
    }

    @Test("Testing that is planned for later is not a checkpoint now", arguments: [
        "Once this merges, we will need UAT.",
        "UAT steps will follow after the migration.",
        "Next up: I will write the review checklist.",
        "Later we should test this on a second machine.",
    ])
    func futureWorkIsNotAnAsk(_ request: String) {
        let reading = FinalHandoff.read(footer(request))
        #expect(!reading.awaitsUserAcceptance, "a plan is not a request")
    }

    @Test("A quoted or fenced example never becomes a checkpoint")
    func quotedProseIsNotAnAsk() {
        let quoted = """
        Here is the template we use:

        > **I need from you:** please test the new flow.

        Nothing needed from you yet.
        """
        #expect(!FinalHandoff.read(quoted).awaitsUserAcceptance)

        let fenced = """
        Example footer:

        ```
        **I need from you:** please review the screens.
        ```
        """
        #expect(!FinalHandoff.read(fenced).awaitsUserAcceptance)
    }

    @Test("A dedicated ‘nothing’ footer stays silent even when it mentions testing")
    func nothingStaysNothing() {
        #expect(!FinalHandoff.read(footer("nothing — UAT is not needed for this")).asksForSomething)
    }
}

/// What the engine does with one: the checkpoint outlives everything the agent does next.
@Suite("Acceptance checkpoints in the queue")
struct AcceptanceCheckpointTests {
    private func acceptanceItem(episode: String, at moment: Date) -> AttentionItem {
        AttentionItem(sessionID: "s1", episodeID: episode, kind: .handoff, source: .explicit,
                      detail: "Please test the new flow", firstSeenAt: moment, lastSeenAt: moment,
                      identity: Fixture.identity(session: "s1"), awaitsUserAcceptance: true)
    }

    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("Background jobs running does not satisfy the checkpoint")
    func runningJobsDoNotAccept() {
        var session = SessionState(identity: Fixture.identity(session: "s1"),
                                   activity: .backgroundWaiting, lastEventAt: t0,
                                   lastActivityAt: t0, episodeID: "E1")
        var registry = BackgroundRegistry()
        _ = registry.apply(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started",
                                                     "task_id": "T1", "uuid": "e1",
                                                     "session_id": "s1"])!,
                           ownedBy: "s1", at: t0)
        session.jobs = registry

        #expect(AlertDispatch.shouldDispatch(acceptanceItem(episode: "E1", at: t0),
                                             session: session, at: t0.addingTimeInterval(60)),
                "a shell running is not the user having tested anything")
    }

    @Test("A background job finishing does not satisfy it either")
    func completedJobsDoNotAccept() {
        var session = SessionState(identity: Fixture.identity(session: "s1"), activity: .working,
                                   lastEventAt: t0, lastActivityAt: t0, episodeID: "E1")
        var registry = BackgroundRegistry()
        _ = registry.apply(BackgroundLifecycleFrame(["type": "system",
                                                     "subtype": "task_notification",
                                                     "task_id": "T1", "uuid": "e1",
                                                     "session_id": "s1", "status": "completed",
                                                     "output_file": "/tmp/x", "summary": "done"])!,
                           ownedBy: "s1", at: t0)
        session.jobs = registry

        #expect(AlertDispatch.shouldDispatch(acceptanceItem(episode: "E1", at: t0),
                                             session: session, at: t0.addingTimeInterval(60)))
    }

    @Test("The parent carrying on by itself does not close the checkpoint")
    func autonomousWorkDoesNotAccept() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Please test the new flow", at: clock.now,
                                    hookEvent: "Stop", awaitsUserAcceptance: true))
        #expect(engine.visibleItems(at: clock.now).count == 1)

        // The agent keeps working — tools run, tasks finish. None of that is the user accepting.
        clock.advance(60)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse"))

        let items = engine.visibleItems(at: clock.now)
        #expect(items.count == 1, "only the user can close an acceptance checkpoint")
        #expect(items.first?.awaitsUserAcceptance == true)
    }

    @Test("The user replying does close it")
    func aUserReplyAccepts() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Please test the new flow", at: clock.now,
                                    hookEvent: "Stop", awaitsUserAcceptance: true))
        clock.advance(60)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "UserPromptSubmit"))

        #expect(engine.visibleItems(at: clock.now).isEmpty,
                "the user typing back is the response the checkpoint was waiting for")
    }

    @Test("An ordinary handoff is still closed by the session resuming work")
    func ordinaryWaitsAreUnchanged() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Which option?", at: clock.now, hookEvent: "Stop"))
        clock.advance(60)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse"))

        #expect(engine.visibleItems(at: clock.now).isEmpty,
                "the existing behaviour for ordinary waits is untouched")
    }

    @Test("Dismissing it explicitly still works")
    func explicitDismissalClosesIt() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Please test the new flow", at: clock.now,
                                    hookEvent: "Stop", awaitsUserAcceptance: true))
        let item = engine.visibleItems(at: clock.now).first!
        _ = engine.dismiss(itemID: item.id)
        #expect(engine.visibleItems(at: clock.now).isEmpty)
    }
}

/// End to end: the hook's own final message, through the translator, to the queue.
@Suite("Acceptance checkpoints end to end")
struct AcceptanceThroughTheHookTests {
    private func stop(_ message: String) -> HookTranslator.Classification {
        HookTranslator.classify(["hook_event_name": "Stop", "last_assistant_message": message])
    }

    @Test("A Stop whose footer hands work over is an acceptance checkpoint")
    func theTranslatorMarksIt() {
        let classification = stop("Built it.\n\n**I need from you:** please test the new flow.")
        #expect(classification.attentionKind == .handoff)
        #expect(classification.awaitsUserAcceptance)
        #expect(classification.detail == "Handed to you to test or review",
                "the reason says what is wanted, not merely that something is")
    }

    @Test("A Stop that asks a question is a handoff, not a checkpoint")
    func questionsAreOrdinaryHandoffs() {
        let classification = stop("**I need from you:** which region should this deploy to?")
        #expect(classification.attentionKind == .handoff)
        #expect(!classification.awaitsUserAcceptance)
    }

    @Test("A Stop that needs nothing is still quiet")
    func nothingIsStillQuiet() {
        #expect(stop("**I need from you:** nothing").attentionKind == .workComplete)
    }

    @Test("A checkpoint outlives a whole cycle of background work")
    func aCheckpointSurvivesTheAgentWorking() {
        let (engine, clock, _) = makeEngine()
        let evidence = BackgroundEvidence.read(from: [
            "background_tasks": [["id": "T1", "type": "shell", "status": "running"]],
            "session_crons": [],
        ], now: clock.now)

        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Handed to you to test or review", at: clock.now,
                                    hookEvent: "Stop", background: evidence,
                                    awaitsUserAcceptance: true))
        #expect(engine.visibleItems(at: clock.now).count == 1)

        // The shell finishes; the agent does more work; a subagent reports in. None of it is the
        // user having tested anything.
        clock.advance(30)
        let finished = BackgroundEvidence.read(from: ["background_tasks": [
            ["id": "T1", "type": "shell", "status": "completed"],
        ], "session_crons": []], now: clock.now)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .workComplete,
                                    at: clock.now, hookEvent: "Stop", background: finished))
        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .housekeeping, at: clock.now,
                                    hookEvent: "SubagentStop"))
        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse"))

        let items = engine.visibleItems(at: clock.now)
        #expect(items.count == 1, "the checkpoint is still there")
        #expect(items.first?.awaitsUserAcceptance == true)
        #expect(items.first?.kind == .handoff)
    }
}

/// A hand-back written as ordinary prose, with no dedicated footer at all.
@Suite("Standalone acceptance handoffs")
struct StandaloneAcceptanceTests {
    private func classify(_ message: String) -> HookTranslator.Classification {
        HookTranslator.classify(["hook_event_name": "Stop", "last_assistant_message": message])
    }

    @Test("The examples people actually write are recognised", arguments: [
        "The build is ready. UAT steps are here:\n1. Open the panel.\n2. Check the approval stays.",
        "Please test the updated functionality and tell me whether it passes.",
        "Please perform user acceptance testing before we continue.",
        "Everything is deployed — have a look and confirm the new screen.",
    ])
    func prosePassesTheHandoffOver(_ message: String) {
        let classification = classify(message)
        #expect(classification.attentionKind == .handoff,
                "a request does not need a label to be a request")
        #expect(classification.awaitsUserAcceptance)
    }

    @Test("A report next to a request is still a request")
    func aMixedMessageIsStillAnAsk() {
        // The whole-message approach failed this: the word "passed" suppressed the actual ask.
        let classification = classify("The automated tests passed. Please test the UI yourself.")
        #expect(classification.awaitsUserAcceptance,
                "each sentence is judged alone, so a report beside an ask does not cancel it")
    }

    @Test("What must stay quiet, stays quiet", arguments: [
        "The old report said:\n> UAT steps are here: open the panel.",
        "Example:\n```text\nPlease test the functionality.\n```",
        "After implementation, I will provide UAT steps for you to test.",
        "Yesterday I asked you to test the functionality; you accepted it.",
        "No UAT is required. The automated test suite passed.",
        "I reviewed the changes and everything looks right.",
    ])
    func quietThingsStayQuiet(_ message: String) {
        #expect(classify(message).attentionKind == .workComplete)
        #expect(!classify(message).awaitsUserAcceptance)
    }

    @Test("A current ask after a past one is read from the current sentence")
    func aCurrentAskAfterHistoryCounts() {
        #expect(classify("Yesterday you tested the old panel.\n\nPlease test the updated "
                         + "functionality before we continue.").awaitsUserAcceptance)
    }

    @Test("Ordinary work reports are not turned into checkpoints", arguments: [
        "Implemented the parser and ran the suite; 713 tests pass.",
        "I checked the logs and found the cause.",
        "Deployed to staging. Nothing needed from you.",
    ])
    func ordinaryReportsAreNotCheckpoints(_ message: String) {
        #expect(!classify(message).awaitsUserAcceptance,
                "not every mention of checking something is a handoff")
    }

    @Test("The dedicated footer still wins where it is used")
    func theFooterPathIsUnchanged() {
        let classification = classify("Done.\n\n**I need from you:** please review the screens.")
        #expect(classification.awaitsUserAcceptance)
        #expect(classification.attentionKind == .handoff)
    }
}
