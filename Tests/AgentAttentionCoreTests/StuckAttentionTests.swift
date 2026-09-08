import Foundation
import Testing
@testable import AgentAttentionCore

/// The reported regression: the count never comes down.
///
/// Two separate causes, found in the installed queue rather than guessed at. One item there had
/// `awaitsUserAcceptance` set from a one-word footer, and its session had since been dropped — so
/// the only evidence that could ever close it (that session's user replying) could never arrive
/// again, and it sat in the count for forty minutes.
@Suite("Stuck attention: over-classified checkpoints")
struct OverClassifiedCheckpointTests {
    private func classify(_ message: String) -> HookTranslator.Classification {
        HookTranslator.classify(["hook_event_name": "Stop", "last_assistant_message": message])
    }

    @Test("A bare verb is not a hand-back", arguments: [
        "**I need from you:** test",
        "**I need from you:** review",
        "**I need from you:** check",
        "**I need from you:** confirm",
    ])
    func aBareVerbIsNotAcceptance(_ message: String) {
        // Production mutation this catches: `addressesTheReader` treating any opening imperative as
        // a request, so a one-word footer becomes a checkpoint that only the user can clear.
        let classification = classify(message)
        #expect(!classification.awaitsUserAcceptance,
                "one word is not a request to go and try something")
    }

    @Test("Writing *about* a pending acceptance does not create one")
    func talkingAboutUatIsNotUat() {
        // Taken from a real report that became a sticky checkpoint on the installed build.
        let message = """
        Done — 16/16 checks passed and everything was cleaned up.

        **I need from you:** nothing for this test. Your general UAT of the panel (background line, \
        job details, "Waiting for you to test it") is still open and still yours.
        """
        #expect(!classify(message).awaitsUserAcceptance,
                "a status report that mentions an open UAT is not itself a new one")
    }

    @Test("A statement about the reader's own pending work is not a request", arguments: [
        "Your review of the migration is still outstanding.",
        "Your UAT of the panel remains open.",
        "The acceptance test you asked about is in the ticket.",
    ])
    func statementsAboutTheReaderAreNotRequests(_ text: String) {
        #expect(!FinalHandoff.readStandaloneAcceptance(text).awaitsUserAcceptance)
    }

    @Test("Genuine hand-backs are unaffected", arguments: [
        "**I need from you:** please test the new flow and tell me if it behaves.",
        "**I need from you:** review the changed screens and confirm they look right.",
        "**I need from you:** try it on your machine and let me know.",
        "**I need from you:** ready for your acceptance testing.",
    ])
    func genuineHandBacksStillCount(_ message: String) {
        #expect(classify(message).awaitsUserAcceptance)
    }
}

/// An ask nobody can answer any more must not sit in the count for ever.
@Suite("Stuck attention: an ask outliving its session")
struct OrphanedCheckpointTests {
    private func raiseCheckpoint(_ engine: AttentionEngine, _ clock: TestClock,
                                 session: String = "s1", pid: Int32 = 4242) {
        engine.ingest(Fixture.event(session: session, signal: .attention, kind: .handoff,
                                    detail: "Handed to you to test or review", at: clock.now,
                                    hookEvent: "Stop",
                                    identity: Fixture.identity(session: session, pid: pid),
                                    awaitsUserAcceptance: true))
    }

    @Test("A checkpoint whose session has gone is resolved, not kept for ever")
    func aDeadSessionsCheckpointIsResolved() {
        // Production mutation this catches: `resolveItem(userResponded: false)` on the sweep's
        // process-gone path, which preserves an acceptance item after its session record is
        // removed. Nothing can then ever clear it: the evidence that closes one is that session's
        // own user reply, and that session no longer exists.
        let (engine, clock, liveness) = makeEngine()
        raiseCheckpoint(engine, clock)
        #expect(engine.visibleItems(at: clock.now).count == 1)

        liveness.kill(Fixture.identity(session: "s1").claudePID!)   // the Claude process is gone
        _ = engine.sweep()

        #expect(engine.sessions["s1"] == nil, "the session record is dropped, as it always was")
        #expect(engine.visibleItems(at: clock.now).isEmpty,
                "an ask nobody can answer any more is not still waiting for an answer")
    }

    @Test("So is one whose session record aged out")
    func aStaleSessionsCheckpointIsResolved() {
        let (engine, clock, _) = makeEngine()
        raiseCheckpoint(engine, clock)
        clock.advance(AttentionConfig.default.staleSessionSeconds + 60)
        _ = engine.sweep()

        #expect(engine.visibleItems(at: clock.now).isEmpty)
    }

    @Test("And one whose session ended")
    func anEndedSessionsCheckpointIsResolved() {
        let (engine, clock, _) = makeEngine()
        raiseCheckpoint(engine, clock)
        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .sessionEnd, at: clock.now,
                                    hookEvent: "SessionEnd"))

        #expect(engine.visibleItems(at: clock.now).isEmpty,
                "the conversation is over; the ask cannot be answered in it")
    }

    @Test("A live session's checkpoint is still untouchable by the agent")
    func aLiveCheckpointStillSurvivesAgentWork() {
        let (engine, clock, _) = makeEngine()
        raiseCheckpoint(engine, clock)

        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse"))
        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .housekeeping, at: clock.now,
                                    hookEvent: "SubagentStop"))
        clock.advance(AttentionConfig.default.maxItemAgeSeconds + 60)
        _ = engine.sweep()

        #expect(engine.visibleItems(at: clock.now).count == 1,
                "the session is alive and the user has said nothing; the ask stands")
    }

    @Test("The count and the list agree, before and after")
    func countAndListAgree() {
        let (engine, clock, liveness) = makeEngine()
        raiseCheckpoint(engine, clock, session: "gone", pid: 4242)
        raiseCheckpoint(engine, clock, session: "alive", pid: 5151)
        #expect(engine.visibleItems(at: clock.now).count == 2)

        // One session's process disappears; the other keeps reporting. They are given distinct
        // pids so only one of them dies.
        liveness.kill(4242)
        _ = engine.sweep()
        clock.advance(5)
        engine.ingest(Fixture.event(session: "alive", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse",
                                    identity: Fixture.identity(session: "alive", pid: 5151)))

        let items = engine.visibleItems(at: clock.now)
        #expect(items.count == 1, "one ask is gone with its session; the other is still owed")
        #expect(items.first?.sessionID == "alive")
    }
}

/// An ordinary question answered, then work resuming, must clear — the other half of the report.
@Suite("Ordinary asks clear when the session gets back to work")
struct OrdinaryAskClearingTests {
    @Test("A question resolves when the session resumes work")
    func aQuestionClearsOnResumedWork() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .question,
                                    detail: "Which option?", at: clock.now))
        #expect(engine.visibleItems(at: clock.now).count == 1)

        clock.advance(20)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse"))
        #expect(engine.visibleItems(at: clock.now).isEmpty)
    }

    @Test("A completed turn clears when the session starts working again")
    func workCompleteClearsOnResumedWork() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        #expect(engine.visibleItems(at: clock.now).count == 1)

        clock.advance(20)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "UserPromptSubmit"))
        #expect(engine.visibleItems(at: clock.now).isEmpty)
    }

    @Test("An ordinary handoff — one that is not a checkpoint — clears the same way")
    func ordinaryHandoffClears() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Which database?", at: clock.now, hookEvent: "Stop"))
        clock.advance(20)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse"))
        #expect(engine.visibleItems(at: clock.now).isEmpty)
    }
}

/// Round two of the same regression: three more ways an ordinary turn became a sticky ask.
@Suite("Stuck attention: round two")
struct StuckAttentionRoundTwoTests {
    private func classify(_ message: String) -> HookTranslator.Classification {
        HookTranslator.classify(["hook_event_name": "Stop", "last_assistant_message": message])
    }

    @Test("A footer that says ‘nothing’ is the answer, whatever the sign-off says")
    func explicitlyNothingWinsOverTheRestOfTheMessage() {
        // Production mutation this catches: `HookTranslator` running the standalone acceptance
        // scan over the whole message even after the dedicated footer said `nothing`. The footer
        // is the turn's own answer to "what do I need from you"; a closing pleasantry underneath
        // it does not overturn that.
        let message = """
        Done — everything is green.

        **I need from you:** nothing

        Let me know if there are any issues.
        """
        let classification = classify(message)
        #expect(!classification.awaitsUserAcceptance)
        #expect(classification.attentionKind == .workComplete, "an explicit ‘nothing’ stays quiet")
    }

    @Test("An ordinary sign-off is not a hand-back", arguments: [
        "Implemented the parser and ran the suite. Let me know if you have questions.",
        "All green. Let me know if that helps.",
        "Deployed to staging — let me know if anything looks off.",
        "Done. Tell me if you want it done differently.",
    ])
    func pleasantriesAreNotCheckpoints(_ message: String) {
        // These end a large share of ordinary turns. Every one of them was becoming an ask only
        // the user could clear, which is how the count filled up with work nobody was waiting on.
        #expect(!classify(message).awaitsUserAcceptance)
    }

    @Test("A real hand-back that also signs off is still a hand-back", arguments: [
        "Please test the new flow and let me know how it goes.",
        "Try it on your machine and let me know.",
    ])
    func aRealAskThatAlsoSignsOffStillCounts(_ message: String) {
        #expect(classify(message).awaitsUserAcceptance)
    }

    @Test("Resuming a session does not leave a second, unlinked ask behind")
    func sessionStartDoesNotOrphanTheCheckpoint() {
        // Production mutation this catches: `applySessionStart` clearing `currentItemID` and
        // opening a new episode even when the acceptance checkpoint it just declined to resolve is
        // still in the queue. The item stays, nothing points at it, and the next signal raises a
        // second row beside it.
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Handed to you to test or review", at: clock.now,
                                    hookEvent: "Stop", awaitsUserAcceptance: true))
        #expect(engine.visibleItems(at: clock.now).count == 1)

        clock.advance(60)
        engine.ingest(Fixture.event(session: "s1", signal: .sessionStart, at: clock.now,
                                    hookEvent: "SessionStart"))
        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .question,
                                    detail: "Which option?", at: clock.now))

        let items = engine.visibleItems(at: clock.now)
        #expect(items.count == 1, "one wait, one row — a resume must not split it in two")
        #expect(items.first?.awaitsUserAcceptance == true,
                "and the ask that is still owed is the one that survives")
    }

    @Test("The surviving checkpoint is still clearable by the user after a resume")
    func theCheckpointStaysClearableAfterAResume() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Handed to you to test or review", at: clock.now,
                                    hookEvent: "Stop", awaitsUserAcceptance: true))
        clock.advance(60)
        engine.ingest(Fixture.event(session: "s1", signal: .sessionStart, at: clock.now,
                                    hookEvent: "SessionStart"))
        clock.advance(10)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "UserPromptSubmit"))

        #expect(engine.visibleItems(at: clock.now).isEmpty,
                "the user replying still closes it, resume or no resume")
    }
}
