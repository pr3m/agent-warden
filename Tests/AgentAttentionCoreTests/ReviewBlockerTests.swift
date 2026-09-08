import Foundation
import Testing
@testable import AgentAttentionCore

/// The five defects a read-only review found in the 0.13.0 candidate. Each of these passed the
/// existing suites — they are new cases, not restatements.
@Suite("Acceptance wording is a request, not a topic")
struct AcceptanceWordingTests {
    private func asks(_ text: String) -> Bool {
        FinalHandoff.readStandaloneAcceptance(text).awaitsUserAcceptance
    }

    @Test("A word that merely contains ‘uat’ or ‘accept’ is not a hand-back", arguments: [
        "The situation is resolved.",
        "The endpoint accepts JSON.",
        "The parser accepts UTF-8 and rejects everything else.",
        "Acceptance criteria are recorded in the ticket.",
        "Evaluating the situation took most of the afternoon.",
        "The graduate is attending a UAT-adjacent conference.",
    ])
    func substringsAreNotRequests(_ text: String) {
        #expect(!asks(text), "‘situation’ contains ‘uat’; that is a spelling coincidence")
    }

    @Test("Talking about testing is not asking for it", arguments: [
        "We should review the architecture next quarter.",
        "The review process is documented in CONTRIBUTING.",
        "I added a test for the parser.",
        "Check-in is at four.",
        "The acceptance test suite runs in CI.",
    ])
    func topicsAreNotRequests(_ text: String) {
        #expect(!asks(text), "a sentence about testing is not a sentence handing work over")
    }

    @Test("The real hand-backs still work", arguments: [
        "UAT steps are here: open the panel and check the row stays.",
        "Please test the updated functionality and tell me whether it passes.",
        "Please perform user acceptance testing before we continue.",
        "Everything is deployed — have a look and confirm the new screen.",
        "Try it on your machine and let me know.",
        "Review the changed screens and confirm they look right.",
        "Ready for your acceptance testing.",
        "The automated tests passed. Please test the UI yourself.",
    ])
    func realHandBacksSurvive(_ text: String) {
        #expect(asks(text), "the examples that were asked for must keep working")
    }
}

/// The bridge's acceptance state, and the order things are validated in.
@Suite("Owned acceptance validation order")
struct OwnedAcceptanceOrderTests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func fixture() -> (BridgeHost, FakeLauncher, String) {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        return (host, launcher, id)
    }

    private func emit(_ host: BridgeHost, _ session: String, _ object: [String: Any]) {
        host.receive(String(data: try! JSONSerialization.data(withJSONObject: object),
                            encoding: .utf8)!, for: session)
    }

    private func key(_ launcher: FakeLauncher, _ session: String) -> String {
        let line = launcher.handle(session)!.writtenLines.last!
        let object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        return object["uuid"] as! String
    }

    @Test("Replaying an old acceptance result does not reopen it against a later prompt")
    func replayedAcceptanceCannotReopen() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "build it")))
        let first = key(launcher, id)
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        let handback: [String: Any] = ["type": "result", "subtype": "success", "session_id": id,
                                       "uuid": "res-A", "user_message_uuid": first,
                                       "is_error": false,
                                       "result": "Done. Please test the new screen."]
        emit(host, id, handback)
        #expect(host.handle(.status(sessionID: id)).session?.attention?.open == true)

        // The user replies, which closes the checkpoint, and a second turn goes out.
        _ = host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "looks fine")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        #expect(host.handle(.status(sessionID: id)).session?.attention == nil)

        // The client replays result A. `complete()` refuses it — and the ask must not come back
        // either, attributed to m2, which nobody handed anything to.
        emit(host, id, handback)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.attention == nil,
                "a replayed answer cannot reopen an ask the user has already dealt with")
        #expect(state?.messages.last?.completedAt == nil)
    }

    @Test("An acceptance result that names a different send raises nothing")
    func foreignAcceptanceRaisesNothing() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "go")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)

        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "x",
                        "user_message_uuid": UUID().uuidString, "is_error": false,
                        "result": "Please test the thing I did for somebody else."])

        #expect(host.handle(.status(sessionID: id)).session?.attention == nil,
                "an answer to another send does not put an ask on this one")
    }

    @Test("A genuine autonomous hand-back is still surfaced")
    func autonomousHandBacksStillCount() {
        let (host, _, id) = fixture()
        // No turn in flight at all: the session finished something on its own and handed it over.
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "auto",
                        "user_message_uuid": NSNull(), "is_error": false,
                        "result": "The migration finished. Please review the output."])

        let attention = host.handle(.status(sessionID: id)).session?.attention
        #expect(attention?.open == true, "work handed over is handed over, prompted or not")
        #expect(attention?.messageID == nil, "and it belongs to no submitted message")
    }

    @Test("Between-submission traffic is remembered, so a later replay cannot slip through")
    func evidenceIsRecordedWithNoTurnInFlight() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "first")))
        let first = key(launcher, id)
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "r1",
                        "user_message_uuid": first, "is_error": false, "result": "first done"])

        // Between turns: a keyed background result. Nothing is in flight, so it settles nothing —
        // but it is evidence that this client stamps join keys, and that must be remembered.
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "bg",
                        "user_message_uuid": UUID().uuidString, "is_error": false,
                        "result": "a background piece"])

        _ = host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "second")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)

        // A keyless result now. From a client known to stamp keys, that is a statement, not the
        // silence of an old producer — so the legacy fallback must not apply.
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "r9",
                        "is_error": false, "result": "something finished"])

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages.last?.completedAt == nil,
                "traffic between submissions is still evidence about the producer")
        #expect(state?.messages.last?.phase == .uncertain)
    }

    @Test("A key naming another send still proves the client stamps keys")
    func mismatchedKeysStillRecordSupport() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "first")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)

        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "other",
                        "user_message_uuid": UUID().uuidString, "is_error": false, "result": "x"])
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "none",
                        "is_error": false, "result": "y"])

        #expect(host.handle(.status(sessionID: id)).session?.messages.last?.completedAt == nil,
                "the first frame proved the client stamps keys; the second one's silence is a fact")
    }

    @Test("An unusable live-task payload does not wipe what we know", arguments: [
        [:] as [String: Any],
        ["tasks": "not an array"] as [String: Any],
        ["tasks": [["no_task_id": "x"]]] as [String: Any],
    ])
    func malformedMembershipIsNotAnEmptySet(_ extra: [String: Any]) {
        let (host, _, id) = fixture()
        emit(host, id, ["type": "system", "subtype": "task_started", "session_id": id,
                        "task_id": "A", "uuid": "e1"])
        #expect(host.handle(.status(sessionID: id)).session?.jobs.first?.state == "running")

        var frame: [String: Any] = ["type": "system", "subtype": "background_tasks_changed",
                                    "session_id": id, "uuid": "l1"]
        extra.forEach { frame[$0.key] = $0.value }
        emit(host, id, frame)

        let job = host.handle(.status(sessionID: id)).session?.jobs.first
        #expect(job?.state == "running",
                "a payload we could not read is not an authoritative empty set")
        #expect(host.handle(.status(sessionID: id)).session?.jobCoverage == "partial")
    }

    @Test("A live-task payload with no session id changes nothing")
    func membershipNeedsAnIdentity() {
        let (host, _, id) = fixture()
        emit(host, id, ["type": "system", "subtype": "task_started", "session_id": id,
                        "task_id": "A", "uuid": "e1"])
        emit(host, id, ["type": "system", "subtype": "background_tasks_changed", "uuid": "l1",
                        "tasks": []])
        #expect(host.handle(.status(sessionID: id)).session?.jobs.first?.state == "running",
                "an unattributed level signal is not this session's membership")
    }

    @Test("A genuinely empty set does still clear membership")
    func aRealEmptySetIsHonoured() {
        let (host, _, id) = fixture()
        emit(host, id, ["type": "system", "subtype": "task_started", "session_id": id,
                        "task_id": "A", "uuid": "e1"])
        emit(host, id, ["type": "system", "subtype": "background_tasks_changed", "session_id": id,
                        "uuid": "l1", "tasks": []])
        #expect(host.handle(.status(sessionID: id)).session?.jobs.first?.state == "absent")
    }
}

/// Merging a second signal into an open item must not lose what that item is.
@Suite("Acceptance survives a merge")
struct AcceptanceMergeTests {
    @Test("A UAT hand-back folded into an open item keeps its acceptance flag")
    func mergingPreservesAcceptance() {
        let (engine, clock, _) = makeEngine()
        // An approval opens the episode.
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))
        // The same episode then hands work over for the user to test.
        clock.advance(5)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Handed to you to test or review", at: clock.now,
                                    hookEvent: "Stop", awaitsUserAcceptance: true))

        let merged = engine.visibleItems(at: clock.now).first
        #expect(merged?.awaitsUserAcceptance == true,
                "the ask that survived the merge is still an acceptance checkpoint")

        // And the agent working afterwards does not clear it.
        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse"))
        #expect(engine.visibleItems(at: clock.now).count == 1,
                "only the user closes an acceptance checkpoint, merged or not")
    }

    @Test("A lower-ranked ordinary signal does not remove an acceptance flag either")
    func aQuieterSignalDoesNotDowngradeIt() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Handed to you to test or review", at: clock.now,
                                    hookEvent: "Stop", awaitsUserAcceptance: true))
        clock.advance(5)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .idle,
                                    detail: "Idle at the prompt", at: clock.now))

        #expect(engine.visibleItems(at: clock.now).first?.awaitsUserAcceptance == true)
    }

    @Test("An ordinary merged item does not gain the flag from nowhere")
    func ordinaryItemsStayOrdinary() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))
        clock.advance(5)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .question,
                                    detail: "Which one?", at: clock.now))

        #expect(engine.visibleItems(at: clock.now).first?.awaitsUserAcceptance == false)
    }
}

/// The second review round: places an acceptance checkpoint could still be lost, and two more
/// substring misfires.
@Suite("Acceptance survives everything except the user")
struct AcceptanceLifetimeTests {
    private func raiseCheckpoint(_ engine: AttentionEngine, _ clock: TestClock) {
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: "Handed to you to test or review", at: clock.now,
                                    hookEvent: "Stop", awaitsUserAcceptance: true))
    }

    @Test("Age alone never expires a checkpoint")
    func sweepDoesNotExpireIt() {
        let (engine, clock, _) = makeEngine()
        raiseCheckpoint(engine, clock)
        #expect(engine.visibleItems(at: clock.now).count == 1)

        // Well past the ordinary item lifetime. An ordinary card expires; an ask put to the user
        // does not answer itself by getting old.
        clock.advance(AttentionConfig.default.maxItemAgeSeconds + 60)
        _ = engine.sweep()

        let items = engine.visibleItems(at: clock.now)
        #expect(items.count == 1, "only a reply or a dismissal closes an acceptance checkpoint")
        #expect(items.first?.awaitsUserAcceptance == true)
    }

    @Test("An ordinary item of the same age does expire, so the sweep still works")
    func sweepStillExpiresOrdinaryItems() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s2", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))
        clock.advance(AttentionConfig.default.maxItemAgeSeconds + 60)
        _ = engine.sweep()
        #expect(engine.visibleItems(at: clock.now).isEmpty)
    }

    @Test("A session resuming does not clear it")
    func sessionStartDoesNotClearIt() {
        let (engine, clock, _) = makeEngine()
        raiseCheckpoint(engine, clock)

        // `claude --resume` reuses the session id and emits SessionStart. The session is alive and
        // the user has answered nothing.
        clock.advance(120)
        engine.ingest(Fixture.event(session: "s1", signal: .sessionStart, at: clock.now,
                                    hookEvent: "SessionStart"))

        #expect(engine.visibleItems(at: clock.now).count == 1,
                "resuming a session is not the user having tested anything")
    }

    @Test("A quiet session does not answer it; a removed one takes it with it")
    func quietIsNotAnAnswerButRemovalEndsTheConversation() {
        // Corrected against the installed build. The earlier rule — keep the checkpoint through a
        // stale-session drop — produced an item whose session no longer existed, so the only
        // evidence that could close it (a reply in that conversation) could never arrive, and it
        // sat in the count indefinitely. Quiet is still not an answer; a session that has been
        // removed is a conversation that cannot be replied to at all.
        let (engine, clock, _) = makeEngine()
        raiseCheckpoint(engine, clock)

        clock.advance(AttentionConfig.default.staleSessionSeconds / 2)
        _ = engine.sweep()
        #expect(engine.visibleItems(at: clock.now).count == 1,
                "the session is still tracked and has said nothing; the ask stands")

        clock.advance(AttentionConfig.default.staleSessionSeconds)
        _ = engine.sweep()
        #expect(engine.sessions["s1"] == nil)
        #expect(engine.visibleItems(at: clock.now).isEmpty,
                "with the record gone, no reply can ever arrive for it")
    }

    @Test("The user replying still closes it, whatever else happened first")
    func theUserStillClosesIt() {
        let (engine, clock, _) = makeEngine()
        raiseCheckpoint(engine, clock)
        clock.advance(AttentionConfig.default.maxItemAgeSeconds + 60)
        _ = engine.sweep()
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "UserPromptSubmit"))
        #expect(engine.visibleItems(at: clock.now).isEmpty)
    }
}

@Suite("Wording: no substring may decide a checkpoint")
struct WordingBoundaryTests {
    private func asks(_ text: String) -> Bool {
        FinalHandoff.readStandaloneAcceptance(text).awaitsUserAcceptance
    }

    @Test("A hand-back phrase buried inside a longer word is not a hand-back", arguments: [
        "This module is a carryover to you for polishing.",
        "The footsteps are hereby recorded in the log.",
        "The changeover to your new plan happens in March.",
    ])
    func handBackPhrasesNeedWordBoundaries(_ text: String) {
        #expect(!asks(text))
    }

    @Test("A past marker buried inside a longer word does not silence a real request", arguments: [
        "We bypassed the auth check for testing, so please verify this is safe.",
        "The parser surpassed its budget — please review the numbers.",
    ])
    func pastMarkersNeedWordBoundaries(_ text: String) {
        #expect(asks(text), "‘bypassed’ is not ‘passed’, and a genuine request must survive it")
    }

    @Test("Real hand-back phrases still work", arguments: [
        "Over to you — the panel is ready.",
        "UAT steps are here: open the panel.",
        "This is ready for your review.",
    ])
    func realPhrasesStillWork(_ text: String) {
        #expect(asks(text))
    }

    @Test("Genuine past and future sentences are still refused", arguments: [
        "The suite passed and I have already reviewed it.",
        "I will provide UAT steps once this merges.",
    ])
    func realMarkersStillRefuse(_ text: String) {
        #expect(!asks(text))
    }
}

@Suite("Membership does not overwrite a settled job")
struct MembershipTerminalTests {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("A completed job still listed as live keeps its own age")
    func terminalJobsKeepTheirObservation() {
        var registry = BackgroundRegistry()
        _ = registry.apply(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started",
                                                     "task_id": "A", "uuid": "e1",
                                                     "session_id": "S"])!,
                           ownedBy: "S", at: t0)
        _ = registry.apply(BackgroundLifecycleFrame(["type": "system",
                                                     "subtype": "task_notification",
                                                     "task_id": "A", "uuid": "e2",
                                                     "session_id": "S", "status": "completed"])!,
                           ownedBy: "S", at: t0.addingTimeInterval(10))

        // The level signal and the edge stream are explicitly not correlated, so a finished job can
        // still appear in a membership payload for a moment.
        registry.applyMembership(taskIDs: ["A"], ownedBy: "S", at: t0.addingTimeInterval(600))

        let job = registry.jobs[0]
        #expect(job.state == .completed)
        #expect(job.observedAt == t0.addingTimeInterval(10),
                "a finished job must not be reported as freshly observed")
        #expect(registry.coverage == .partial, "and the two signals disagreeing is on the record")
    }
}
