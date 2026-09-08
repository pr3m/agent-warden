import Foundation
import Testing
@testable import AgentAttentionCore

/// Behaviour of the single attention queue: what raises an alert, what stays quiet, and what
/// takes an alert away again.
@Suite("Attention queue")
struct AttentionEngineTests {

    // MARK: - Transitions

    @Test("Ordinary work raises nothing")
    func ordinaryWorkIsQuiet() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .sessionStart, at: clock.now, hookEvent: "SessionStart"))
        clock.advance(5)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PreToolUse"))
        clock.advance(5)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))

        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1")?.activity == .working)
    }

    @Test("A permission prompt raises an explicit approval")
    func permissionPromptRaisesApproval() {
        let (engine, clock, _) = makeEngine()
        let effects = engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .approval,
            detail: "Permission needed: Bash", at: clock.now
        ))

        #expect(effects.raisedItems.count == 1)
        let item = engine.visibleItems().first
        #expect(item?.kind == .approval)
        #expect(item?.source == .explicit)
        #expect(item?.isSuspected == false)
        #expect(engine.pendingCount == 1)
        #expect(engine.session("s1")?.activity == .awaitingUser)
    }

    @Test("Work resuming resolves the item")
    func workResumingResolvesItem() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))
        #expect(engine.pendingCount == 1)

        clock.advance(20)
        let effects = engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))

        #expect(effects.resolutionReasons == [.sessionResumedWork])
        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1")?.activity == .working)
    }

    @Test("Stop raises work-complete and the next prompt clears it")
    func stopThenPrompt() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        #expect(engine.visibleItems().first?.kind == .workComplete)

        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "UserPromptSubmit"))
        #expect(engine.pendingCount == 0)
    }

    @Test("SessionEnd clears everything for that session")
    func sessionEndClears() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .question, at: clock.now))
        clock.advance(5)
        let effects = engine.ingest(Fixture.event(session: "s1", signal: .sessionEnd, at: clock.now, hookEvent: "SessionEnd"))

        #expect(effects.resolutionReasons == [.sessionEnded])
        #expect(effects.dropReasons == [.sessionEnded])
        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1") == nil)
    }

    // MARK: - One waiting episode, however many signals describe it

    @Test("A permission request followed by Claude Code's own prompt is one wait, not two")
    func permissionRequestThenNotification() {
        let (engine, clock, _) = makeEngine()
        // What actually happens: PermissionRequest names the tool, then a generic
        // Notification/permission_prompt arrives a few seconds later for the same decision.
        let first = engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .approval,
            detail: "Permission needed: Bash", at: clock.now, hookEvent: "PermissionRequest"
        ))
        clock.advance(6)
        let second = engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .approval,
            detail: "Permission prompt open", at: clock.now, hookEvent: "Notification"
        ))

        #expect(first.raisedItems.count == 1)
        #expect(second.raisedItems.isEmpty, "the second description of the same wait must not alert again")
        #expect(second.repeatedItems.count == 1)
        #expect(engine.allItems().count == 1)
        #expect(engine.allItems().first?.detail == "Permission needed: Bash", "the more specific reason is kept")
        #expect(engine.allItems().first?.occurrences == 2)
    }

    @Test("Stop followed by an idle prompt is one wait, not two")
    func stopThenIdlePrompt() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        clock.advance(60)
        let second = engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .idle, at: clock.now, hookEvent: "Notification"))

        #expect(second.raisedItems.isEmpty)
        #expect(engine.allItems().count == 1)
        #expect(engine.visibleItems().first?.kind == .workComplete, "finishing is a better description than idling")
    }

    @Test("A snooze survives the next signal about the same wait")
    func snoozeSurvivesFollowUpSignal() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))
        let id = engine.visibleItems()[0].id
        engine.snooze(itemID: id, for: 600)
        #expect(engine.pendingCount == 0)

        clock.advance(6)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission prompt open", at: clock.now))

        #expect(engine.pendingCount == 0, "a follow-up description must not cancel the snooze")
        #expect(engine.snoozedCount == 1)
        #expect(engine.allItems().first?.id == id, "it is still the same item")
    }

    @Test("A dismissal holds for the rest of the wait, not for a fixed number of seconds")
    func dismissHoldsForTheEpisode() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))
        engine.dismiss(itemID: engine.visibleItems()[0].id)
        #expect(engine.pendingCount == 0)

        // Claude Code keeps describing the same still-open decision, minutes later.
        for delay in [6.0, 60.0, 600.0] {
            clock.advance(delay)
            engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission prompt open", at: clock.now))
            #expect(engine.pendingCount == 0, "still the wait the user already dismissed")
        }
    }

    @Test("Real work starts a new wait, so the next ask alerts again")
    func workStartsANewEpisode() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))
        engine.dismiss(itemID: engine.visibleItems()[0].id)

        clock.advance(5)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        clock.advance(5)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Write", at: clock.now))

        #expect(engine.pendingCount == 1, "a new ask after real work is genuinely new")
        #expect(engine.visibleItems().first?.detail == "Permission needed: Write")
    }

    @Test("A question is not downgraded by a generic permission prompt that follows")
    func questionKeepsItsSpecificity() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .question, at: clock.now, hookEvent: "PreToolUse"))
        clock.advance(3)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, at: clock.now, hookEvent: "Notification"))

        #expect(engine.allItems().count == 1)
        #expect(engine.visibleItems().first?.kind == .question)
    }

    @Test("A vaguer first signal is sharpened by a more specific one")
    func vagueSignalIsUpgraded() {
        let (engine, clock, _) = makeEngine()
        // A confirmed completion opens the wait; the approval that follows is the same wait, said
        // more precisely. (An idle prompt could not open it — nothing generic can.)
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        clock.advance(2)
        let effects = engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .approval,
            detail: "Permission needed: Bash", at: clock.now
        ))

        #expect(effects.raisedItems.isEmpty, "still the same wait — no second alert")
        #expect(engine.visibleItems().first?.kind == .approval)
        #expect(engine.visibleItems().first?.detail == "Permission needed: Bash")
    }

    @Test("The same event delivered twice is ignored")
    func replayedEventIgnored() {
        let (engine, clock, _) = makeEngine()
        let event = Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now)
        let first = engine.ingest(event)
        let second = engine.ingest(event)

        #expect(first.raisedItems.count == 1)
        #expect(second.isEmpty, "replaying a spool file after a crash must not double-count")
        #expect(engine.allItems().first?.occurrences == 1)
    }

    // MARK: - Ordering guards

    @Test("Stale activity cannot silence a newer ask")
    func staleActivityIgnored() {
        let (engine, clock, _) = makeEngine()
        clock.advance(100)
        let activityTime = clock.now
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: activityTime, hookEvent: "PostToolUse"))
        clock.advance(10)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))
        #expect(engine.pendingCount == 1)

        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: activityTime, hookEvent: "PostToolUse"))
        #expect(engine.pendingCount == 1)
    }

    @Test("A stale ask cannot resurrect itself after the session went back to work")
    func staleAttentionIgnored() {
        let (engine, clock, _) = makeEngine()
        let askedAt = clock.now
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: askedAt))
        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        #expect(engine.pendingCount == 0)

        // The same ask, replayed from a spool file that outlived a crash.
        clock.advance(5)
        let replay = engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .approval,
            detail: "Permission needed: Bash", at: askedAt
        ))
        #expect(replay.isEmpty)
        #expect(engine.pendingCount == 0, "an ask the session has already worked past is over")
    }

    @Test("A stale SessionStart cannot clear an alert raised after it")
    func staleSessionStartIgnored() {
        let (engine, clock, _) = makeEngine()
        let startedAt = clock.now
        engine.ingest(Fixture.event(session: "s1", signal: .sessionStart, at: startedAt, hookEvent: "SessionStart"))
        clock.advance(20)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))
        #expect(engine.pendingCount == 1)

        engine.ingest(Fixture.event(session: "s1", signal: .sessionStart, at: startedAt, hookEvent: "SessionStart", id: "replay"))
        #expect(engine.pendingCount == 1)
    }

    @Test("A stale SessionEnd cannot drop a session that has since resumed")
    func staleSessionEndIgnored() {
        let (engine, clock, _) = makeEngine()
        let endedAt = clock.now
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now.addingTimeInterval(-10), hookEvent: "PostToolUse"))
        clock.advance(30)
        // `claude --resume` reuses the session id, so a replayed end could land after a new start.
        engine.ingest(Fixture.event(session: "s1", signal: .sessionStart, at: clock.now, hookEvent: "SessionStart"))
        let effects = engine.ingest(Fixture.event(session: "s1", signal: .sessionEnd, at: endedAt, hookEvent: "SessionEnd"))

        #expect(effects.isEmpty)
        #expect(engine.session("s1") != nil)
    }

    @Test("An answer landing in the same second as the question still clears it")
    func sameSecondAnswerResolves() throws {
        let (engine, clock, _) = makeEngine()
        let askedAt = clock.now
        // Sub-second ordering has to survive the JSON round-trip the spool actually performs.
        let ask = Fixture.event(session: "s1", signal: .attention, kind: .question, at: askedAt, hookEvent: "PreToolUse")
        let answer = Fixture.event(session: "s1", signal: .activity, at: askedAt.addingTimeInterval(0.15), hookEvent: "PostToolUse")

        let encodedAsk = try JSONCoding.decoder.decode(EmittedEvent.self, from: JSONCoding.encoder.encode(ask))
        let encodedAnswer = try JSONCoding.decoder.decode(EmittedEvent.self, from: JSONCoding.encoder.encode(answer))
        #expect(encodedAnswer.occurredAt > encodedAsk.occurredAt, "the encoder must not round both to the same second")

        engine.ingest(encodedAsk)
        #expect(engine.pendingCount == 1)
        let effects = engine.ingest(encodedAnswer)
        #expect(effects.resolutionReasons == [.sessionResumedWork])
        #expect(engine.pendingCount == 0)
    }

    @Test("Events arriving out of order end in the same state as in order")
    func outOfOrderBatchIsOrdered() {
        let inOrder = makeEngine()
        let shuffled = makeEngine()
        let base = Fixture.origin

        let events = [
            Fixture.event(session: "s1", signal: .sessionStart, at: base, hookEvent: "SessionStart", id: "a"),
            Fixture.event(session: "s1", signal: .activity, at: base.addingTimeInterval(1), hookEvent: "PostToolUse", id: "b"),
            Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: base.addingTimeInterval(2), id: "c"),
            Fixture.event(session: "s1", signal: .activity, at: base.addingTimeInterval(3), hookEvent: "PostToolUse", id: "d"),
            Fixture.turnComplete(session: "s1", at: base.addingTimeInterval(4), id: "e"),
        ]
        inOrder.0.ingest(events)
        shuffled.0.ingest([events[4], events[1], events[3], events[0], events[2]])

        #expect(inOrder.0.visibleItems().map(\.kind) == [.workComplete])
        #expect(shuffled.0.visibleItems().map(\.kind) == [.workComplete])
        #expect(shuffled.0.session("s1")?.activity == inOrder.0.session("s1")?.activity)
    }

    // MARK: - Multiple sessions

    @Test("Multiple sessions queue independently and sort by urgency")
    func multipleSessionsSort() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        clock.advance(1)
        engine.ingest(Fixture.event(session: "s2", signal: .attention, kind: .approval, at: clock.now))
        clock.advance(1)
        // s3 only ever reports an idle prompt. That is a state, not a request, and with nothing
        // confirming its turn finished it stays out of the queue entirely.
        engine.ingest(Fixture.event(session: "s3", signal: .attention, kind: .idle, at: clock.now))
        clock.advance(1)
        engine.ingest(Fixture.event(session: "s4", signal: .attention, kind: .question, at: clock.now))

        #expect(engine.pendingCount == 3)
        #expect(engine.visibleItems().map(\.sessionID) == ["s4", "s2", "s1"])
        #expect(engine.session("s3")?.currentItemID == nil)
    }

    @Test("Resolving one session leaves the others alone")
    func resolvingOneSession() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))
        engine.ingest(Fixture.event(session: "s2", signal: .attention, kind: .approval, detail: "Permission needed: Write", at: clock.now))

        clock.advance(10)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))

        #expect(engine.visibleItems().map(\.sessionID) == ["s2"])
    }

    @Test("Two sessions in the same project stay separate")
    func sameProjectTwoSessions() {
        let (engine, clock, _) = makeEngine()
        let a = Fixture.identity(session: "s1", project: "alpha", pid: 1)
        let b = Fixture.identity(session: "s2", project: "alpha", pid: 2)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now, identity: a))
        engine.ingest(Fixture.event(session: "s2", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now, identity: b))

        #expect(engine.pendingCount == 2, "identical asks from different sessions are different asks")
    }

    // MARK: - Snooze and dismiss

    @Test("Snooze hides an item until its deadline, then returns it once")
    func snoozeHidesThenReturns() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, at: clock.now))
        let id = engine.visibleItems()[0].id

        #expect(engine.snooze(itemID: id, for: 600))
        #expect(engine.pendingCount == 0)
        #expect(engine.snoozedCount == 1)

        clock.advance(300)
        #expect(engine.sweep().unsnoozedItems.isEmpty)

        clock.advance(301)
        #expect(engine.sweep().unsnoozedItems.count == 1)
        #expect(engine.pendingCount == 1)
        #expect(engine.sweep().unsnoozedItems.isEmpty, "an item comes back exactly once")
    }

    @Test("Snoozing or dismissing something that no longer exists is a no-op")
    func actionsOnUnknownItems() {
        let (engine, _, _) = makeEngine()
        #expect(engine.snooze(itemID: "nope") == false)
        #expect(engine.dismiss(itemID: "nope").isEmpty)
    }

    @Test("Snoozing one card leaves every other card exactly as it was")
    func snoozeIsScopedToOneItem() throws {
        let (engine, clock, _) = makeEngine()
        for (id, kind) in [("s1", AttentionKind.approval), ("s2", .question), ("s3", .error)] {
            engine.ingest(Fixture.event(session: id, signal: .attention, kind: kind, at: clock.now))
        }
        let target = try #require(engine.allItems().first { $0.sessionID == "s2" })
        let others = engine.allItems().filter { $0.sessionID != "s2" }

        engine.snooze(itemID: target.id, for: 600)

        #expect(engine.allItems().count == 3, "snoozing removes nothing")
        #expect(engine.snoozedCount == 1)
        #expect(engine.visibleItems().map(\.sessionID).sorted() == ["s1", "s3"])
        #expect(engine.item(id: target.id)?.snoozedUntil != nil)
        for other in others {
            #expect(engine.item(id: other.id)?.snoozedUntil == nil, "nobody else got snoozed")
            #expect(engine.session(other.sessionID)?.currentItemID == other.id, "and nobody else lost their card")
        }
    }

    @Test("Dismissing one card removes exactly that card")
    func dismissIsScopedToOneItem() throws {
        let (engine, clock, _) = makeEngine()
        for (id, kind) in [("s1", AttentionKind.approval), ("s2", .question), ("s3", .error)] {
            engine.ingest(Fixture.event(session: id, signal: .attention, kind: kind, at: clock.now))
        }
        let target = try #require(engine.allItems().first { $0.sessionID == "s2" })

        let effects = engine.dismiss(itemID: target.id)

        #expect(effects.resolutionReasons == [.dismissed])
        #expect(engine.allItems().map(\.sessionID).sorted() == ["s1", "s3"])
        #expect(engine.session("s2")?.currentItemID == nil)
        #expect(engine.session("s2")?.episodeDismissed == true, "only that session's episode is closed")
        #expect(engine.session("s1")?.episodeDismissed == false)
        #expect(engine.session("s3")?.episodeDismissed == false)
    }

    @Test("Dismissing an item that is not there changes nothing")
    func dismissUnknownItemIsANoOp() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, at: clock.now))
        #expect(engine.dismiss(itemID: "not-a-real-id").isEmpty)
        #expect(engine.pendingCount == 1)
    }

    @Test("Dismiss all empties the queue")
    func dismissAll() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "a", at: clock.now))
        engine.ingest(Fixture.event(session: "s2", signal: .attention, kind: .question, detail: "b", at: clock.now))
        engine.ingest(Fixture.event(session: "s3", signal: .attention, kind: .error, detail: "c", at: clock.now))

        #expect(engine.dismissAll().count == 3)
        #expect(engine.pendingCount == 0)
        #expect(engine.allItems().isEmpty)
    }

    @Test("A snoozed item still disappears when its session resumes work")
    func snoozedItemResolvedByWork() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        engine.snooze(itemID: engine.visibleItems()[0].id, for: 600)

        clock.advance(10)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "UserPromptSubmit"))
        #expect(engine.allItems().isEmpty)
    }

    // MARK: - Liveness and staleness

    @Test("A dead process drops the session and its item")
    func deadProcessDropsSession() {
        let (engine, clock, liveness) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        #expect(engine.pendingCount == 1)

        liveness.kill(4242)
        clock.advance(20)
        let effects = engine.sweep()

        #expect(effects.resolutionReasons == [.processGone])
        #expect(effects.dropReasons == [.processGone])
        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1") == nil)
    }

    @Test("A stale session is dropped even while the process lives")
    func staleSessionDropped() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))

        clock.advance(AttentionConfig.default.staleSessionSeconds + 60)
        #expect(engine.sweep().dropReasons == [.stale])
        #expect(engine.session("s1") == nil)
    }

    @Test("Items expire if nobody ever deals with them")
    func itemsExpire() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))

        clock.advance(AttentionConfig.default.maxItemAgeSeconds + 60)
        #expect(engine.sweep().resolutionReasons.contains(.expired))
        #expect(engine.allItems().isEmpty)
    }

    @Test("A session with no pid falls back to staleness alone")
    func sessionWithoutPid() {
        let (engine, clock, liveness) = makeEngine()
        let identity = Fixture.identity(session: "s1", pid: nil, startedAt: nil)
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now, identity: identity))

        liveness.kill(4242)
        clock.advance(60)
        engine.sweep()
        #expect(engine.pendingCount == 1, "we cannot prove anything about a session with no pid")

        clock.advance(AttentionConfig.default.staleSessionSeconds)
        engine.sweep()
        #expect(engine.pendingCount == 0)
    }

    // MARK: - Elapsed time is never evidence

    @Test("Hours of silence produce nothing at all")
    func silenceIsNotAnEvent() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PreToolUse"))

        // Legitimate work runs for hours. The passage of time is not a signal, and there is no
        // threshold here to tune — inferred inactivity was removed outright.
        for _ in 0..<12 {
            clock.advance(3600)
            let effects = engine.sweep()
            #expect(effects.raisedItems.isEmpty)
            #expect(effects.repeatedItems.isEmpty)
            #expect(engine.pendingCount == 0)
            #expect(engine.allItems().isEmpty)
        }
    }

    @Test("Days of silence still produce nothing, whatever the session was doing", arguments: [
        SessionActivityState.working, .awaitingUser, .unknown, .discovered,
    ])
    func silenceAcrossStates(state: SessionActivityState) {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        clock.advance(3 * 24 * 3600)
        // The session record ages out on staleness, but no alert is ever raised on the way.
        #expect(engine.sweep().raisedItems.isEmpty)
    }

    @Test("A replayed inferred-stall record cannot surface")
    func replayedStallIgnored() {
        // An old spool file, or a queue written by a build that still had the feature.
        let (engine, clock, _) = makeEngine()
        let effects = engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .suspectedStall,
            source: .inferred, detail: "No activity for 12m", at: clock.now
        ))
        #expect(effects.raisedItems.isEmpty)
        #expect(engine.pendingCount == 0)
        #expect(engine.allItems().isEmpty)
    }

    @Test("Restoring an old queue drops the inferred stall and keeps everything genuine")
    func restoreDropsOnlyTheStall() throws {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)

        // Build a queue the way an older version would have left it: a real ask, a snoozed real
        // ask, and an inferred stall.
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))
        engine.ingest(Fixture.event(session: "s2", signal: .attention, kind: .question,
                                    detail: "Asked you a question", at: clock.now))
        let snoozed = try #require(engine.visibleItems().first { $0.sessionID == "s2" })
        engine.snooze(itemID: snoozed.id, for: 600)

        var snapshot = engine.snapshot()
        let stall = AttentionItem(
            sessionID: "s3", episodeID: "ep-3", kind: .suspectedStall, source: .inferred,
            detail: "No activity for 12m while the process is still running",
            firstSeenAt: clock.now, lastSeenAt: clock.now,
            identity: Fixture.identity(session: "s3", project: "gamma", pid: 300)
        )
        snapshot.items.append(stall)
        snapshot.sessions["s3"] = SessionState(
            identity: stall.identity, activity: .awaitingUser,
            lastEventAt: clock.now, lastActivityAt: clock.now,
            episodeID: "ep-3", currentItemID: stall.id
        )

        let revived = AttentionEngine(config: .default, clock: TestClock(clock.now.addingTimeInterval(5)),
                                      liveness: StubLiveness(), restoring: snapshot)

        #expect(revived.allItems().count == 2, "the stall is gone; the two real asks are not")
        #expect(revived.allItems().allSatisfy { $0.kind != .suspectedStall })
        #expect(revived.visibleItems().map(\.sessionID) == ["s1"])
        #expect(revived.snoozedCount == 1, "the snooze on the genuine ask survives")
        #expect(revived.session("s3")?.currentItemID == nil, "and nothing still points at the dropped item")
        #expect(revived.session("s3")?.activity == .unknown,
                "clearing the link is not enough — the row must stop saying it is waiting for you")
    }

    @Test("A legacy completion card nothing supports is not re-presented as a milestone")
    func restoreDropsUnsupportedCompletion() throws {
        // A queue written before completion evidence existed. The card says the turn finished; the
        // session has nothing showing that it did. Presenting it again would assert something we
        // cannot stand behind, so it goes — quietly, and without touching the real ask beside it.
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))
        var snapshot = engine.snapshot()

        let legacy = AttentionItem(
            sessionID: "s9", episodeID: "ep-9", kind: .workComplete, source: .explicit,
            detail: "Turn complete — waiting for you",
            firstSeenAt: clock.now, lastSeenAt: clock.now,
            identity: Fixture.identity(session: "s9", project: "legacy", pid: 900)
        )
        snapshot.items.append(legacy)
        snapshot.sessions["s9"] = SessionState(
            identity: legacy.identity, activity: .awaitingUser,
            lastEventAt: clock.now, lastActivityAt: clock.now,
            episodeID: "ep-9", currentItemID: legacy.id
        )

        let revived = AttentionEngine(config: .default, clock: TestClock(clock.now.addingTimeInterval(5)),
                                      liveness: StubLiveness(), restoring: snapshot)

        #expect(revived.allItems().map(\.kind) == [.approval], "the ask survives; the unsupported claim does not")
        #expect(revived.session("s9")?.currentItemID == nil)
        #expect(revived.session("s9")?.activity == .unknown)
    }

    @Test("A completion card the evidence still confirms is restored intact")
    func restoreKeepsConfirmedCompletion() throws {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        #expect(engine.pendingCount == 1)

        let revived = AttentionEngine(config: .default, clock: TestClock(clock.now.addingTimeInterval(5)),
                                      liveness: StubLiveness(), restoring: engine.snapshot())
        #expect(revived.allItems().map(\.kind) == [.workComplete], "this one is backed by evidence")
    }

    @Test("A completion whose evidence has since gone stale is not restored")
    func restoreDropsExpiredCompletion() throws {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        let snapshot = engine.snapshot()

        // Restored long after the reading it rests on stopped being a claim about now.
        let later = clock.now.addingTimeInterval(AttentionConfig.default.backgroundEvidenceTTLSeconds + 600)
        let revived = AttentionEngine(config: .default, clock: TestClock(later),
                                      liveness: StubLiveness(), restoring: snapshot)
        #expect(revived.allItems().isEmpty)
        #expect(revived.session("s1")?.activity == .unknown)
    }

    @Test("An old snapshot decodes a suspectedStall value without failing")
    func oldWireValueStillDecodes() throws {
        // Compatibility only: the value parses, and then nothing acts on it.
        let json = #"{"kind":"suspectedStall","source":"inferred"}"#
        struct Probe: Decodable { let kind: AttentionKind; let source: SignalSource }
        let probe = try JSONCoding.decoder.decode(Probe.self, from: Data(json.utf8))
        #expect(probe.kind == .suspectedStall)
    }

    // MARK: - Restart recovery

    @Test("State survives encoding and restart")
    func stateSurvivesRestart() throws {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))
        engine.ingest(Fixture.turnComplete(session: "s2", at: clock.now))
        let snoozeTarget = try #require(engine.visibleItems().first(where: { $0.sessionID == "s2" }))
        engine.snooze(itemID: snoozeTarget.id, for: 600)

        let data = try JSONCoding.encoder.encode(engine.snapshot())
        let restored = try JSONCoding.decoder.decode(EngineSnapshot.self, from: data)

        let laterClock = TestClock(clock.now.addingTimeInterval(30))
        let revived = AttentionEngine(config: .default, clock: laterClock, liveness: StubLiveness(), restoring: restored)

        #expect(revived.allItems().count == 2)
        #expect(revived.pendingCount == 1)
        #expect(revived.snoozedCount == 1)
        #expect(revived.visibleItems().first?.kind == .approval)
        #expect(revived.session("s1")?.currentItemID == revived.visibleItems().first?.id)

        laterClock.advance(600)
        #expect(revived.sweep().unsnoozedItems.count == 1, "a snooze deadline outlives a restart")
    }

    @Test("A wait carries on being one wait across a restart")
    func episodeSurvivesRestart() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))
        let snapshot = engine.snapshot()

        let laterClock = TestClock(clock.now.addingTimeInterval(20))
        let revived = AttentionEngine(config: .default, clock: laterClock, liveness: StubLiveness(), restoring: snapshot)

        let effects = revived.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .approval,
            detail: "Permission prompt open", at: laterClock.now
        ))
        #expect(effects.raisedItems.isEmpty, "restarting the app does not restart the wait")
        #expect(revived.allItems().count == 1)
    }

    @Test("A restart after a long gap invents nothing")
    func restartInventsNothing() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PreToolUse"))
        let snapshot = engine.snapshot()

        // The app was closed for six hours. That is not a signal about the session either.
        let laterClock = TestClock(clock.now.addingTimeInterval(6 * 3600))
        let revived = AttentionEngine(config: .default, clock: laterClock, liveness: StubLiveness(), restoring: snapshot)

        #expect(revived.sweep().raisedItems.isEmpty)
        laterClock.advance(3600)
        #expect(revived.sweep().raisedItems.isEmpty)
        #expect(revived.pendingCount == 0)
    }

    @Test("A restart drops sessions whose process died while the app was closed")
    func restartDropsDeadSessions() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        let snapshot = engine.snapshot()

        let liveness = StubLiveness()
        liveness.kill(4242)
        let laterClock = TestClock(clock.now.addingTimeInterval(60))
        let revived = AttentionEngine(config: .default, clock: laterClock, liveness: liveness, restoring: snapshot)

        #expect(revived.sweep().dropReasons == [.processGone])
        #expect(revived.pendingCount == 0)
    }

    @Test("A state file from a newer version is ignored, not guessed at")
    func futureSnapshotIgnored() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "x", at: clock.now))
        var snapshot = engine.snapshot()
        snapshot.version = EngineSnapshot.currentVersion + 1

        let revived = AttentionEngine(config: .default, clock: TestClock(clock.now), liveness: StubLiveness(), restoring: snapshot)
        #expect(revived.allItems().isEmpty)
    }

    @Test("An item restored without its session record is still tracked and swept")
    func orphanItemIsAdopted() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "x", at: clock.now))
        var snapshot = engine.snapshot()
        snapshot.sessions = [:]

        let liveness = StubLiveness()
        let revived = AttentionEngine(config: .default, clock: TestClock(clock.now), liveness: liveness, restoring: snapshot)
        #expect(revived.pendingCount == 1)

        liveness.kill(4242)
        #expect(revived.sweep().dropReasons == [.processGone])
        #expect(revived.pendingCount == 0)
    }

    // MARK: - Malformed and hostile input

    @Test("Events from an unknown schema are ignored")
    func unknownSchemaIgnored() {
        let (engine, clock, _) = makeEngine()
        var event = Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "x", at: clock.now)
        event.schema = EmittedEvent.currentSchema + 1
        #expect(engine.ingest(event).isEmpty)
        #expect(engine.pendingCount == 0)
    }

    @Test("Events with no session id are ignored")
    func missingSessionIdIgnored() {
        let (engine, clock, _) = makeEngine()
        let identity = Fixture.identity(session: "")
        #expect(engine.ingest(Fixture.event(session: "", signal: .attention, kind: .approval, detail: "x", at: clock.now, identity: identity)).isEmpty)
    }

    @Test("Ancient spool files do not resurrect alerts")
    func ancientEventsIgnored() {
        let (engine, clock, _) = makeEngine()
        let old = clock.now.addingTimeInterval(-(AttentionConfig.default.maxItemAgeSeconds + 3600))
        #expect(engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "x", at: old)).isEmpty)
        #expect(engine.pendingCount == 0)
    }

    @Test("Attention events with no kind are ignored")
    func attentionWithoutKindIgnored() {
        let (engine, clock, _) = makeEngine()
        #expect(engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: nil, detail: "x", at: clock.now)).isEmpty)
        #expect(engine.pendingCount == 0)
    }

    @Test("Turning off work-complete alerts keeps the session tracked but quiet")
    func workCompleteAlertsOff() {
        var config = AttentionConfig.default
        config.notifyOnWorkComplete = false
        let (engine, clock, _) = makeEngine(config: config)

        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        #expect(engine.pendingCount == 0, "the alert is off")
        #expect(engine.session("s1")?.activity == .awaitingUser,
                "but the evidence confirmed the turn finished, so that is what the state says")

        clock.advance(4000)
        #expect(engine.sweep().raisedItems.isEmpty, "a finished session is not a stalled one")
    }

    /// The toggle is a preference about *alerts*. It must not make the app stop knowing things.
    @Test("Completion alerts off still reads the evidence: unknown stays unknown")
    func alertsOffStillReadsUnknownEvidence() {
        var config = AttentionConfig.default
        config.notifyOnWorkComplete = false
        let (engine, clock, _) = makeEngine(config: config)

        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .workComplete,
                                    at: clock.now, hookEvent: "Stop",
                                    background: BackgroundEvidence.unknown(at: clock.now)))

        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1")?.activity == .unknown,
                "an unreadable payload is not 'waiting at the prompt', whatever the toggle says")
        #expect(engine.session("s1")?.background?.availability == .unknown,
                "and the reading is still recorded")
    }

    @Test("Completion alerts off still reads the evidence: a pause stays a pause")
    func alertsOffStillReadsBackgroundWork() {
        var config = AttentionConfig.default
        config.notifyOnWorkComplete = false
        let (engine, clock, _) = makeEngine(config: config)

        engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .workComplete, at: clock.now, hookEvent: "Stop",
            background: BackgroundEvidence(availability: .reported, running: 1,
                                           types: ["shell"], observedAt: clock.now)))

        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1")?.activity == .backgroundWaiting)
        #expect(engine.sessionsWaitingOnBackgroundWork(at: clock.now).count == 1,
                "the panel still shows what it is doing; it just does not alert")
    }

    @Test("Completion alerts off never hides a failed background task")
    func alertsOffStillRaisesFailures() {
        var config = AttentionConfig.default
        config.notifyOnWorkComplete = false
        let (engine, clock, _) = makeEngine(config: config)

        let effects = engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .workComplete, at: clock.now, hookEvent: "Stop",
            background: BackgroundEvidence(availability: .none, failed: 1, observedAt: clock.now)))

        #expect(effects.raisedItems.count == 1, "turning off completion alerts is not turning off errors")
        #expect(engine.visibleItems().first?.kind == .error)
        #expect(engine.session("s1")?.activity == .awaitingUser)
    }

    @Test("Completion alerts off leaves a real ask and its snooze alone")
    func alertsOffPreservesAsks() throws {
        var config = AttentionConfig.default
        config.notifyOnWorkComplete = false
        config.notifyOnIdle = false
        let (engine, clock, _) = makeEngine(config: config)

        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))
        let itemID = try #require(engine.allItems().first?.id)
        engine.snooze(itemID: itemID, for: 600)

        clock.advance(30)
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        clock.advance(5)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .idle, at: clock.now))

        #expect(engine.allItems().count == 1)
        #expect(engine.allItems().first?.kind == .approval, "the ask is still the ask")
        #expect(engine.allItems().first?.snoozedUntil != nil, "and it is still snoozed")
        #expect(engine.session("s1")?.activity == .awaitingUser)
    }

    @Test("Turning off idle alerts keeps the prompt quiet without inventing a state")
    func idleAlertsOff() {
        var config = AttentionConfig.default
        config.notifyOnIdle = false
        let (engine, clock, _) = makeEngine(config: config)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        clock.advance(10)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .idle, at: clock.now))

        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1")?.activity == .unknown,
                "an idle prompt with nothing behind it is uncertainty, not a request")
    }

    // MARK: - A replayed stall asserts nothing

    @Test("A replayed stall cannot turn a working session into one that needs you")
    func replayedStallLeavesWorkingSessionAlone() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        #expect(engine.session("s1")?.activity == .working)

        clock.advance(30)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .suspectedStall,
                                    source: .inferred, detail: "No activity for 12m", at: clock.now))

        #expect(engine.session("s1")?.activity == .working, "silence is not evidence of anything")
        #expect(engine.pendingCount == 0)
    }

    @Test("A replayed stall cannot displace a real ask or a background pause")
    func replayedStallLeavesRealStateAlone() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, at: clock.now))
        engine.ingest(Fixture.event(
            session: "s2", signal: .attention, kind: .workComplete, at: clock.now, hookEvent: "Stop",
            background: BackgroundEvidence(availability: .reported, running: 1, observedAt: clock.now)))
        #expect(engine.session("s2")?.activity == .backgroundWaiting)

        clock.advance(30)
        for id in ["s1", "s2"] {
            engine.ingest(Fixture.event(session: id, signal: .attention, kind: .suspectedStall,
                                        source: .inferred, at: clock.now))
        }

        #expect(engine.visibleItems().map(\.kind) == [.approval])
        #expect(engine.session("s1")?.activity == .awaitingUser)
        #expect(engine.session("s2")?.activity == .backgroundWaiting, "still paused, not 'needs you'")
    }

    // MARK: - Confirmed evidence cannot be reused after work resumes

    @Test("A bare completion notice cannot reuse an older confirmed Stop")
    func confirmedEvidenceExpiresWhenWorkResumes() {
        // Stop confirms the turn finished; the user replies; the session works; then a generic
        // `agent_completed` arrives carrying no evidence of its own. Reusing the earlier Stop would
        // manufacture a milestone for a turn that has not ended.
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        #expect(engine.pendingCount == 1)

        clock.advance(20)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "UserPromptSubmit"))
        #expect(engine.pendingCount == 0, "work resumed, so the card went")

        clock.advance(20)
        let effects = engine.ingest(Fixture.event(session: "s1", signal: .attention,
                                                  kind: .workComplete, at: clock.now,
                                                  hookEvent: "Notification"))

        #expect(effects.raisedItems.isEmpty, "no evidence of its own, and the old evidence is spent")
        #expect(engine.pendingCount == 0)
        #expect(engine.session("s1")?.activity == .unknown)
        #expect(engine.session("s1")?.background?.isConfirmedComplete == true,
                "the historical reading is kept for the record, it just cannot confirm anything now")
    }

    @Test("A new Stop after work resumes confirms again on its own evidence")
    func freshEvidenceConfirmsAgain() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        clock.advance(20)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "UserPromptSubmit"))
        clock.advance(20)
        let effects = engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))

        #expect(effects.raisedItems.count == 1, "this one brought its own evidence")
        #expect(engine.visibleItems().first?.kind == .workComplete)
    }

    @Test("An engine built with nonsense configuration still behaves")
    func hostileConfigIsClamped() {
        var config = AttentionConfig.default
        config.sweepIntervalSeconds = -100
        config.maxVisibleCards = 0
        config.stallThresholdSeconds = -1
        config.snoozeDurationSeconds = -60
        let (engine, clock, _) = makeEngine(config: config)

        #expect(engine.config.sweepIntervalSeconds >= 1)
        #expect(engine.config.maxVisibleCards >= 1)
        #expect(engine.config.stallThresholdSeconds >= 30)

        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, at: clock.now))
        let id = engine.visibleItems()[0].id
        engine.snooze(itemID: id, for: -500)
        #expect(engine.snoozedCount == 1, "a negative snooze must not make the item vanish or reappear instantly")
    }

    // MARK: - Heartbeats

    @Test("Heartbeats feed ordinary work into the engine")
    func heartbeatsCarryActivity() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.turnComplete(session: "s1", at: clock.now))
        #expect(engine.pendingCount == 1)

        clock.advance(30)
        let beat = SessionHeartbeat(
            identity: Fixture.identity(session: "s1"),
            lastEventAt: clock.now,
            lastHookEvent: "PostToolUse",
            lastSignal: .activity
        )
        #expect(engine.applyHeartbeats([beat]).resolutionReasons == [.sessionResumedWork])
        #expect(engine.pendingCount == 0)
    }

    @Test("An attention heartbeat does not age out the spool record that matches it")
    func attentionHeartbeatDoesNotBlockItsOwnEvent() {
        let (engine, clock, _) = makeEngine()
        let moment = clock.now
        // The emitter writes both files with the same timestamp; the app may read the heartbeat
        // directory first. The spool record must still land.
        let beat = SessionHeartbeat(
            identity: Fixture.identity(session: "s1"),
            lastEventAt: moment,
            lastHookEvent: "Notification",
            lastSignal: .attention
        )
        engine.applyHeartbeats([beat])
        let effects = engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .approval,
            detail: "Permission needed: Bash", at: moment
        ))
        #expect(effects.raisedItems.count == 1)
        #expect(engine.pendingCount == 1)
    }

    @Test("Rereading the same heartbeat changes nothing")
    func heartbeatRereadIsInert() {
        let (engine, clock, _) = makeEngine()
        let beat = SessionHeartbeat(
            identity: Fixture.identity(session: "s1"),
            lastEventAt: clock.now,
            lastHookEvent: "PostToolUse",
            lastSignal: .activity
        )
        engine.applyHeartbeats([beat])
        clock.advance(5)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash", at: clock.now))

        engine.applyHeartbeats([beat])
        engine.applyHeartbeats([beat])
        #expect(engine.pendingCount == 1, "the watcher rereads the directory constantly; that must be inert")
    }

    @Test("Heartbeats from an unknown schema are skipped")
    func heartbeatSchemaGuard() {
        let (engine, clock, _) = makeEngine()
        var beat = SessionHeartbeat(
            identity: Fixture.identity(session: "s1"),
            lastEventAt: clock.now,
            lastHookEvent: "PostToolUse",
            lastSignal: .activity
        )
        beat.schema = SessionHeartbeat.currentSchema + 1
        #expect(engine.applyHeartbeats([beat]).isEmpty)
        #expect(engine.session("s1") == nil)
    }
}
