import Foundation
import Testing
@testable import AgentAttentionCore

/// "Something is new" and "something is still waiting on me" are different facts.
///
/// They were counted as one number, and that is what makes a badge stop working: a handoff that
/// deliberately waits until it is answered looks exactly like an approval that arrived a second ago,
/// so the badge is permanently lit and people stop reading it. Seeing is separate from deciding —
/// looking at the panel must change what is *new* and change nothing else.
@Suite("What is new, and what is still waiting")
struct SeenStateTests {

    private func engineWithTwoAsks() -> (AttentionEngine, TestClock, [String]) {
        let (engine, clock, _) = makeEngine()
        var ids: [String] = []
        for (index, session) in ["S-1", "S-2"].enumerated() {
            let effects = engine.ingest([Fixture.event(
                session: session, signal: .attention, kind: .approval,
                detail: "Permission needed \(index)",
                at: clock.now.addingTimeInterval(Double(index)))])
            ids += effects.compactMap(\.itemID)
        }
        return (engine, clock, ids)
    }

    @Test("A brand new ask is both waiting and new")
    func aNewAskIsUnseen() {
        let (engine, _, _) = engineWithTwoAsks()
        #expect(engine.pendingCount == 2)
        #expect(engine.unseenCount == 2, "nobody has looked at either of them yet")
    }

    @Test("Looking at the panel makes them no longer new, and changes nothing else")
    func lookingClearsOnlyTheNewness() {
        let (engine, clock, _) = engineWithTwoAsks()

        let marked = engine.markVisibleAsSeen(at: clock.now)

        #expect(marked == 2)
        #expect(engine.unseenCount == 0, "the badge goes out")
        #expect(engine.pendingCount == 2, "and the work is still waiting — seeing is not deciding")
    }

    @Test("An ask that arrives after you looked is new again, on its own")
    func aLaterAskIsNewOnItsOwn() {
        let (engine, clock, _) = engineWithTwoAsks()
        engine.markVisibleAsSeen(at: clock.now)

        _ = engine.ingest([Fixture.event(session: "S-3", signal: .attention, kind: .approval,
                                         detail: "Permission needed", at: clock.now)])

        #expect(engine.pendingCount == 3)
        #expect(engine.unseenCount == 1, "only the one that arrived since the last look")
    }

    @Test("Looking twice does not move the first look")
    func theTimestampMeansFirstLook() {
        let (engine, clock, _) = engineWithTwoAsks()
        let first = clock.now
        engine.markVisibleAsSeen(at: first)

        let marked = engine.markVisibleAsSeen(at: first.addingTimeInterval(600))

        #expect(marked == 0, "nothing was new, so nothing changed")
        #expect(engine.snapshot().items.allSatisfy { $0.seenAt == first })
    }

    @Test("Being seen never resolves anything, including a handoff that is waiting on a reply")
    func seeingDoesNotResolve() {
        let (engine, clock, _) = makeEngine()
        // A `Stop` with both task arrays read cleanly and empty — the only shape that confirms a
        // turn finished — carrying a handoff footer, which is what makes it wait for a reply.
        var handoff = Fixture.turnComplete(session: "S-1", at: clock.now)
        handoff.awaitsUserAcceptance = true
        handoff.detail = "Asked you to try it"
        _ = engine.ingest([handoff])
        #expect(engine.pendingCount == 1)

        engine.markVisibleAsSeen(at: clock.now)

        #expect(engine.pendingCount == 1, "a handoff still needs an answer after you have read it")
        #expect(engine.unseenCount == 0, "but it is no longer news")
    }

    @Test("Dismissing removes it from both counts")
    func dismissingRemovesItEntirely() {
        let (engine, _, ids) = engineWithTwoAsks()
        guard let first = ids.first else { Issue.record("no item to dismiss"); return }

        _ = engine.dismiss(itemID: first)

        #expect(engine.pendingCount == 1)
        #expect(engine.unseenCount == 1, "the one left is still unread")
    }

    @Test("Seen-ness survives a restart, so a queue you have read does not come back as new")
    func seenSurvivesAReload() {
        let (engine, clock, _) = engineWithTwoAsks()
        engine.markVisibleAsSeen(at: clock.now)

        let (restored, _, _) = makeEngine(restoring: engine.snapshot())

        #expect(restored.pendingCount == 2)
        #expect(restored.unseenCount == 0, "a restart is not a reason to re-alert somebody")
    }
}

/// Where a row sits after you have been to it.
///
/// Arriving at a tab used to delete the row, on the grounds that landing there meant it was handled.
/// It does not: opening a session to look at it is routinely how you discover it still needs you,
/// and the question was then gone from the queue for good. A visit now demotes instead — below
/// everything unvisited, above everything that is merely working, so the top of the list is always
/// what has not been dealt with.
@Suite("Where a visited row sits")
struct VisitedOrderingTests {

    private func twoAsks() -> (AttentionEngine, TestClock, [String]) {
        let (engine, clock, _) = makeEngine()
        var ids: [String] = []
        for (index, session) in ["S-1", "S-2"].enumerated() {
            ids += engine.ingest([Fixture.event(
                session: session, signal: .attention, kind: .approval,
                detail: "Permission needed \(index)",
                at: clock.now.addingTimeInterval(Double(index)))]).compactMap(\.itemID)
        }
        return (engine, clock, ids)
    }

    @Test("Going to a session's tab keeps the row and moves it down")
    func aVisitDemotesRatherThanDeletes() {
        let (engine, clock, ids) = twoAsks()
        guard let first = ids.first else { Issue.record("no item"); return }
        #expect(engine.visibleItems().first?.id == first, "it starts at the top")

        #expect(engine.markVisited(itemID: first, at: clock.now))

        #expect(engine.pendingCount == 2, "the row is still there — arriving is not answering")
        #expect(engine.visibleItems().last?.id == first, "and it is now below the one not been to")
    }

    @Test("An unvisited row outranks a visited one whatever kind each is")
    func unvisitedOutranksEverything() {
        let (engine, clock, _) = makeEngine()
        // A question (rank 100) outranks an error (rank 80) by kind — but not once you have been
        // to the question.
        let question = engine.ingest([Fixture.event(session: "S-1", signal: .attention, kind: .question,
                                                    detail: "Which way?", at: clock.now)])
            .compactMap(\.itemID).first
        _ = engine.ingest([Fixture.event(session: "S-2", signal: .attention, kind: .error,
                                         detail: "It broke", at: clock.now.addingTimeInterval(1))])
        guard let question else { Issue.record("no question item"); return }
        #expect(engine.visibleItems().first?.id == question, "by kind, the question leads")

        _ = engine.markVisited(itemID: question, at: clock.now)

        #expect(engine.visibleItems().last?.id == question,
                "somewhere you have not been outranks somewhere you have, whatever it is about")
    }

    @Test("Visiting is not seeing twice: it counts as looked at, and never as answered")
    func visitingAlsoCountsAsSeen() {
        let (engine, clock, ids) = twoAsks()
        guard let first = ids.first else { Issue.record("no item"); return }

        _ = engine.markVisited(itemID: first, at: clock.now)

        #expect(engine.unseenCount == 1, "the row you clicked is no longer new")
        #expect(engine.pendingCount == 2, "and nothing was resolved by clicking it")
    }

    @Test("A second visit does not move the first one")
    func theFirstVisitIsTheOneRecorded() {
        let (engine, clock, ids) = twoAsks()
        guard let first = ids.first else { Issue.record("no item"); return }
        #expect(engine.markVisited(itemID: first, at: clock.now))

        #expect(!engine.markVisited(itemID: first, at: clock.now.addingTimeInterval(600)),
                "already visited, so nothing changed")
    }

    @Test("Visiting something that is not there changes nothing")
    func anUnknownItemIsIgnored() {
        let (engine, clock, _) = twoAsks()
        #expect(!engine.markVisited(itemID: "not-an-item", at: clock.now))
        #expect(engine.pendingCount == 2)
    }

    @Test("Where you have been survives a restart")
    func visitsSurviveAReload() {
        let (engine, clock, ids) = twoAsks()
        guard let first = ids.first else { Issue.record("no item"); return }
        _ = engine.markVisited(itemID: first, at: clock.now)

        let (restored, _, _) = makeEngine(restoring: engine.snapshot())

        #expect(restored.visibleItems().last?.id == first,
                "a restart must not push a row you have dealt with back to the top")
    }
}

/// Clicking a row is stronger evidence than the panel having been open.
///
/// The dot has to go out on the click itself. It used to depend on the jump to the terminal
/// succeeding — and worse, a row that had both a session record and an open request handed over only
/// the session when clicked, so the item id was dropped and nothing was marked at all. The row kept
/// its unread dot after you had plainly just clicked it and landed in its tab.
@Suite("Clicking a row marks it read")
struct ClickMarksReadTests {

    private func oneAsk() -> (AttentionEngine, TestClock, String) {
        let (engine, clock, _) = makeEngine()
        let ids = engine.ingest([Fixture.event(session: "S-1", signal: .attention, kind: .approval,
                                               detail: "Permission needed", at: clock.now)])
            .compactMap(\.itemID)
        return (engine, clock, ids.first ?? "")
    }

    @Test("One click, one row, read straight away")
    func aClickMarksThatRowRead() {
        let (engine, clock, id) = oneAsk()
        #expect(engine.unseenCount == 1)

        #expect(engine.markSeen(itemID: id, at: clock.now))

        #expect(engine.unseenCount == 0)
        #expect(engine.pendingCount == 1, "read is not answered — the row stays")
    }

    @Test("Reading one row does not read the others")
    func onlyTheClickedRowIsMarked() {
        let (engine, clock, first) = oneAsk()
        _ = engine.ingest([Fixture.event(session: "S-2", signal: .attention, kind: .approval,
                                         detail: "Another", at: clock.now.addingTimeInterval(1))])

        _ = engine.markSeen(itemID: first, at: clock.now)

        #expect(engine.unseenCount == 1, "the row nobody clicked is still unread")
        #expect(engine.pendingCount == 2)
    }

    @Test("Being read is not being visited: the row keeps its place until you get there")
    func readingDoesNotDemote() {
        let (engine, clock, first) = oneAsk()
        _ = engine.ingest([Fixture.event(session: "S-2", signal: .attention, kind: .approval,
                                         detail: "Another", at: clock.now.addingTimeInterval(1))])

        _ = engine.markSeen(itemID: first, at: clock.now)

        #expect(engine.visibleItems().first?.id == first,
                "clearing the dot must not reorder the queue under the pointer")
    }

    @Test("Clicking twice changes nothing the second time")
    func theFirstReadIsTheOneRecorded() {
        let (engine, clock, id) = oneAsk()
        #expect(engine.markSeen(itemID: id, at: clock.now))
        #expect(!engine.markSeen(itemID: id, at: clock.now.addingTimeInterval(60)))
    }

    @Test("A row that is not there cannot be marked")
    func anUnknownRowIsIgnored() {
        let (engine, clock, _) = oneAsk()
        #expect(!engine.markSeen(itemID: "not-an-item", at: clock.now))
        #expect(engine.unseenCount == 1)
    }

    @Test("Going to the tab still counts as read, even if nothing marked it first")
    func visitingImpliesReading() {
        let (engine, clock, id) = oneAsk()
        _ = engine.markVisited(itemID: id, at: clock.now)
        #expect(engine.unseenCount == 0)
    }
}
