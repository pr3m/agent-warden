import Foundation
import Testing
@testable import AgentAttentionCore

/// How a discovered session and a hook-derived one live together.
///
/// A discovery says a session *exists*. It never says the session wants anything. Everything below
/// is about keeping that line: discovered sessions are visible but explicitly unknown, hooks are
/// always authoritative when they arrive, and nothing the user did to a card survives being
/// re-discovered.
@Suite("Discovery merge")
struct DiscoveryMergeTests {

    private func discovery(
        session: String,
        project: String = "alpha",
        pid: Int32 = 4242,
        title: String? = "alpha work",
        status: String? = "busy",
        updatedAt: Date? = Fixture.origin
    ) -> DiscoveredSession {
        let record = RegistryRecord(
            sessionID: session,
            pid: pid,
            procStart: Fixture.origin.addingTimeInterval(-3600),
            cwd: "/Users/dev/code/\(project)",
            title: title,
            titleSource: "derived",
            version: "2.1.261",
            status: status,
            startedAt: Fixture.origin.addingTimeInterval(-3600),
            updatedAt: updatedAt
        )
        return DiscoveredSession(record: record, identity: record.sessionIdentity())
    }

    private func report(_ sessions: [DiscoveredSession], present: Bool = true, inspectable: Bool = true) -> DiscoveryReport {
        DiscoveryReport(
            scannedAt: Fixture.origin,
            registryPresent: present,
            inspectionAvailable: inspectable,
            filesConsidered: sessions.count,
            malformed: 0,
            oversized: 0,
            verified: sessions,
            rejected: []
        )
    }

    // MARK: - A discovery is not an event

    @Test("A discovered session appears, but nothing is claimed about it")
    func discoveredSessionIsVisibleButUnknown() {
        let (engine, clock, _) = makeEngine()
        let added = engine.apply(discovery: report([discovery(session: "s1")]), at: clock.now)

        #expect(added == 1)
        let session = engine.session("s1")
        #expect(session?.activity == .discovered)
        #expect(session?.hasHookEvidence == false, "no hook has been seen for it yet")
        #expect(session?.identity.projectName == "alpha")
        #expect(engine.pendingCount == 0, "existing is not waiting")
        #expect(engine.allItems().isEmpty)
    }

    @Test("Registry busy is never turned into attention, work or a stall")
    func busyIsNotAttention() {
        // `status: busy` in the registry goes stale by design — it can be a quarter of an hour old.
        // Reading it as "this session is working" or "this session needs you" would be a fabrication.
        let (engine, clock, _) = makeEngine()
        engine.apply(discovery: report([discovery(session: "s1", status: "busy")]), at: clock.now)

        #expect(engine.pendingCount == 0)
        #expect(engine.sessions.values.filter { $0.activity == .working }.isEmpty)

        clock.advance(AttentionConfig.default.stallThresholdSeconds * 4)
        let effects = engine.sweep()
        #expect(effects.raisedItems.isEmpty, "silence from a session we have never heard from is not a stall")
        #expect(engine.pendingCount == 0)
    }

    @Test("Discovered sessions are not counted as working, whatever the registry says", arguments: ["busy", "idle", "unknown", nil])
    func neverCountedAsWorking(status: String?) {
        let (engine, clock, _) = makeEngine()
        engine.apply(discovery: report([discovery(session: "s1", status: status)]), at: clock.now)
        #expect(engine.sessions["s1"]?.activity == .discovered)
        #expect(engine.sessions.values.contains { $0.activity == .working } == false)
    }

    @Test("Re-scanning does not pile up sessions or reset anything")
    func rediscoveryIsIdempotent() {
        let (engine, clock, _) = makeEngine()
        #expect(engine.apply(discovery: report([discovery(session: "s1")]), at: clock.now) == 1)
        clock.advance(30)
        #expect(engine.apply(discovery: report([discovery(session: "s1")]), at: clock.now) == 0)
        #expect(engine.sessions.count == 1)
    }

    // MARK: - Hooks are authoritative

    @Test("A later hook takes over the session without duplicating it")
    func hookTakesOver() {
        let (engine, clock, _) = makeEngine()
        engine.apply(discovery: report([discovery(session: "s1", project: "alpha")]), at: clock.now)
        #expect(engine.sessions.count == 1)

        clock.advance(60)
        // The same session, now reporting for itself from a worktree the registry never saw.
        let hookIdentity = Fixture.identity(session: "s1", project: "alpha-worktree")
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse", identity: hookIdentity))

        #expect(engine.sessions.count == 1, "merged by full session id, not duplicated")
        let session = engine.session("s1")
        #expect(session?.activity == .working)
        #expect(session?.hasHookEvidence == true)
        #expect(session?.identity.cwd == "/Users/dev/code/alpha-worktree")
    }

    @Test("A later discovery never overwrites a newer hook cwd with the startup one")
    func registryNeverOverwritesHookCwd() {
        let (engine, clock, _) = makeEngine()
        let hookIdentity = Fixture.identity(session: "s1", project: "alpha-worktree")
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse", identity: hookIdentity))

        clock.advance(30)
        // The registry still carries the directory the session was launched in.
        engine.apply(discovery: report([discovery(session: "s1", project: "alpha")]), at: clock.now)

        #expect(engine.session("s1")?.identity.cwd == "/Users/dev/code/alpha-worktree")
        #expect(engine.session("s1")?.activity == .working, "a discovery is not a state change")
        #expect(engine.session("s1")?.hasHookEvidence == true)
    }

    @Test("A discovery fills gaps a hook left, and only gaps")
    func discoveryFillsOnlyGaps() {
        let (engine, clock, _) = makeEngine()
        // A hook that could not identify the process — it happens when Claude Code is launched from
        // something other than a terminal.
        let sparse = SessionIdentity(sessionID: "s1", cwd: "/Users/dev/code/alpha-worktree")
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse", identity: sparse))
        #expect(engine.session("s1")?.identity.claudePID == nil)

        clock.advance(5)
        engine.apply(discovery: report([discovery(session: "s1", pid: 777)]), at: clock.now)

        let identity = engine.session("s1")?.identity
        #expect(identity?.claudePID == 777, "the gap is filled")
        #expect(identity?.cwd == "/Users/dev/code/alpha-worktree", "what the hook knew is untouched")
        #expect(identity?.title == "alpha work", "and the registry title is added")
    }

    @Test("Attention, snooze and dismissal survive a re-scan")
    func userStateSurvivesRediscovery() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))
        let item = engine.visibleItems()[0]
        engine.snooze(itemID: item.id, for: 600)

        clock.advance(30)
        engine.apply(discovery: report([discovery(session: "s1")]), at: clock.now)

        #expect(engine.allItems().count == 1)
        #expect(engine.allItems().first?.id == item.id, "the same item, not a replacement")
        #expect(engine.snoozedCount == 1, "the snooze is still running")
        #expect(engine.session("s1")?.currentItemID == item.id)
        #expect(engine.session("s1")?.activity == .awaitingUser)
    }

    @Test("A dismissed wait is not reopened by a re-scan")
    func dismissalSurvivesRediscovery() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now))
        engine.dismiss(itemID: engine.visibleItems()[0].id)

        clock.advance(20)
        engine.apply(discovery: report([discovery(session: "s1")]), at: clock.now)
        clock.advance(5)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission prompt open", at: clock.now))

        #expect(engine.pendingCount == 0, "still the wait the user dismissed")
        #expect(engine.session("s1")?.episodeDismissed == true)
    }

    // MARK: - Disappearing

    @Test("A discovered-only session goes when its registry record does")
    func disappearedRecordIsDropped() {
        let (engine, clock, _) = makeEngine()
        engine.apply(discovery: report([discovery(session: "s1"), discovery(session: "s2")]), at: clock.now)
        #expect(engine.sessions.count == 2)

        clock.advance(30)
        engine.apply(discovery: report([discovery(session: "s1")]), at: clock.now)
        #expect(engine.sessions.keys.sorted() == ["s1"])
    }

    @Test("A hook-covered session is never dropped just because the registry forgot it")
    func hookCoveredSessionSurvivesRegistryLoss() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))

        clock.advance(30)
        engine.apply(discovery: report([]), at: clock.now)
        #expect(engine.session("s1") != nil)
        #expect(engine.session("s1")?.activity == .working)
    }

    @Test("A failed or unavailable scan removes nothing")
    func failedScanRemovesNothing() {
        let (engine, clock, _) = makeEngine()
        engine.apply(discovery: report([discovery(session: "s1")]), at: clock.now)

        clock.advance(30)
        engine.apply(discovery: report([], present: false), at: clock.now)
        #expect(engine.session("s1") != nil, "a missing registry directory is not evidence of anything")

        engine.apply(discovery: report([], inspectable: false), at: clock.now)
        #expect(engine.session("s1") != nil, "nor is being unable to inspect processes")
    }

    @Test("A discovered session whose process dies is swept away like any other")
    func deadDiscoveredSessionIsSwept() {
        let (engine, clock, liveness) = makeEngine()
        engine.apply(discovery: report([discovery(session: "s1", pid: 4242)]), at: clock.now)

        liveness.kill(4242)
        clock.advance(20)
        #expect(engine.sweep().dropReasons == [.processGone])
        #expect(engine.session("s1") == nil)
    }

    @Test("A long-lived discovered session does not go stale while it keeps being found")
    func rediscoveryKeepsASessionFresh() {
        let (engine, clock, _) = makeEngine()
        engine.apply(discovery: report([discovery(session: "s1", updatedAt: Fixture.origin)]), at: clock.now)

        // Well past the staleness horizon, but we can still see it every cycle.
        clock.advance(AttentionConfig.default.staleSessionSeconds + 3600)
        engine.apply(discovery: report([discovery(session: "s1", updatedAt: Fixture.origin)]), at: clock.now)
        #expect(engine.sweep().dropReasons.isEmpty)
        #expect(engine.session("s1") != nil)
    }

    // MARK: - Persistence

    @Test("Discovery state survives a save and restore")
    func discoveryStateRoundTrips() throws {
        let (engine, clock, _) = makeEngine()
        engine.apply(discovery: report([discovery(session: "s1")]), at: clock.now)

        let data = try JSONCoding.encoder.encode(engine.snapshot())
        let restored = try JSONCoding.decoder.decode(EngineSnapshot.self, from: data)
        let revived = AttentionEngine(config: .default, clock: TestClock(clock.now),
                                      liveness: StubLiveness(), restoring: restored)

        #expect(revived.session("s1")?.activity == .discovered)
        #expect(revived.session("s1")?.hasHookEvidence == false)
    }

    @Test("A snapshot written before discovery existed still loads")
    func oldSnapshotStillLoads() throws {
        // Exactly the shape version 2 wrote: no hasHookEvidence, no discovery.
        let json = """
        {"version":2,"savedAt":"2026-09-06T00:00:00.000+00:00","items":[],"recentEventIDs":[],
         "sessions":{"s1":{"identity":{"sessionID":"s1","cwd":"/Users/dev/code/alpha"},
         "activity":"working","lastEventAt":"2026-09-06T00:00:00.000+00:00",
         "lastActivityAt":"2026-09-06T00:00:00.000+00:00","episodeID":"ep-1",
         "episodeDismissed":false}}}
        """
        let snapshot = try JSONCoding.decoder.decode(EngineSnapshot.self, from: Data(json.utf8))
        let engine = AttentionEngine(config: .default, clock: TestClock(Fixture.origin),
                                     liveness: StubLiveness(), restoring: snapshot)

        let session = try #require(engine.session("s1"))
        #expect(session.activity == .working)
        #expect(session.hasHookEvidence == true, "it came from hooks, so it is covered")
        #expect(session.discovery == nil)
    }

    @Test("An activity value from a newer version does not break loading")
    func unknownActivityDegrades() throws {
        let json = """
        {"version":2,"savedAt":"2026-09-06T00:00:00.000+00:00","items":[],"recentEventIDs":[],
         "sessions":{"s1":{"identity":{"sessionID":"s1","cwd":"/x"},"activity":"somethingNew",
         "lastEventAt":"2026-09-06T00:00:00.000+00:00","lastActivityAt":"2026-09-06T00:00:00.000+00:00",
         "episodeID":"ep-1","episodeDismissed":false}}}
        """
        let snapshot = try JSONCoding.decoder.decode(EngineSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.sessions["s1"]?.activity == .unknown)
    }
}

/// The specific failure modes an independent review found in the first cut of discovery.
@Suite("Discovery review regressions")
struct DiscoveryReviewTests {

    private func record(session: String = "s1", pid: Int32 = 4242, cwd: String = "/Users/dev/code/alpha",
                        title: String? = "alpha") -> RegistryRecord {
        RegistryRecord(sessionID: session, pid: pid,
                       procStart: Date(timeIntervalSince1970: 1_000_000),
                       cwd: cwd, title: title,
                       startedAt: Date(timeIntervalSince1970: 1_000_000),
                       updatedAt: Fixture.origin)
    }

    private func report(_ verified: [DiscoveredSession], rejected: [RejectedRecord] = [],
                        present: Bool = true, inspectable: Bool = true) -> DiscoveryReport {
        DiscoveryReport(scannedAt: Fixture.origin, registryPresent: present,
                        inspectionAvailable: inspectable, filesConsidered: verified.count + rejected.count,
                        malformed: 0, oversized: 0, verified: verified, rejected: rejected)
    }

    // MARK: - The identity we carry forward must survive a liveness check

    @Test("An accepted session carries the kernel's birth time, not the registry's string")
    func acceptedIdentityUsesKernelBirthTime() throws {
        // The registry renders `procStart` in UTC with no zone in it. Storing that as the birth
        // time leaves it hours wrong on any machine that is not on UTC — and then the very next
        // liveness sweep declares the session dead and deletes it.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aw-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A birth time deliberately three hours away from the string's naive local reading.
        let kernelBirth = SessionRegistry.parseProcStart("Sun Sep  6 08:24:43 2026")!.timeIntervalSince1970
        let stub = StubProcessIdentity()
        stub.add(pid: 4242, startedAt: kernelBirth, command: "claude",
                 executablePath: "/Users/dev/.local/share/claude/versions/2.1.261",
                 tty: "/dev/ttys009")
        try JSONSerialization.data(withJSONObject: [
            "sessionId": "s1", "pid": 4242, "procStart": "Sun Sep  6 08:24:43 2026",
            "cwd": "/Users/dev/code/alpha",
        ]).write(to: root.appendingPathComponent("sessions/4242.json"))

        let found = try #require(SessionRegistry.scan(root: root, identity: stub).verified.first)

        #expect(found.identity.claudePIDStartedAt == kernelBirth,
                "the snapshot that passed verification is what gets stored")
        #expect(found.identity.tty == "/dev/ttys009", "and the tty it came with")

        // The downstream check that actually matters: would liveness keep this session?
        let liveness = StubLiveness()
        #expect(liveness.probe(pid: found.identity.claudePID!,
                               startedAt: found.identity.claudePIDStartedAt) == .alive)
        // And with the same tolerance the real prober uses, the stored value matches the kernel.
        #expect(abs((found.identity.claudePIDStartedAt ?? 0) - kernelBirth) <= 2)
    }

    // MARK: - Discovery must not shadow a hook that was already in flight

    @Test("A hook emitted before a scan but consumed after it still wins")
    func hookInFlightDuringScanIsNotLost() {
        // Discovery runs on a background queue, so a hook written at t=99 can easily be read at
        // t=101 — after a scan stamped t=100 has already been applied. If discovery advanced the
        // session's event clock, that hook would be discarded as stale and the session would sit
        // there labelled "awaiting first hook" while it was actually asking for something.
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)

        let found = DiscoveredSession(record: record(), identity: record().sessionIdentity(birth: 1))
        engine.apply(discovery: report([found]), at: Date(timeIntervalSince1970: 100))
        #expect(engine.session("s1")?.hasHookEvidence == false)

        clock.set(Date(timeIntervalSince1970: 101))
        let effects = engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .approval, detail: "Permission needed: Bash",
            at: Date(timeIntervalSince1970: 99)
        ))

        #expect(effects.raisedItems.count == 1, "the first real hook must win")
        #expect(engine.session("s1")?.hasHookEvidence == true)
        #expect(engine.session("s1")?.activity == .awaitingUser)
    }

    @Test("Genuine ordering is still enforced once a hook has spoken")
    func orderingStillHoldsAfterFirstHook() {
        let clock = TestClock(Date(timeIntervalSince1970: 200))
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.apply(discovery: report([DiscoveredSession(record: record(), identity: record().sessionIdentity(birth: 1))]),
                     at: Date(timeIntervalSince1970: 100))

        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: Date(timeIntervalSince1970: 150)))
        #expect(engine.pendingCount == 1)

        // A replayed activity from before the ask must still not clear it.
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: Date(timeIntervalSince1970: 120),
                                    hookEvent: "PostToolUse"))
        #expect(engine.pendingCount == 1)
    }

    @Test("A session with no hook yet reports no last-event time at all")
    func noLastEventBeforeFirstHook() {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.apply(discovery: report([DiscoveredSession(record: record(), identity: record().sessionIdentity(birth: 1))]),
                     at: clock.now)

        let session = engine.session("s1")
        #expect(session?.lastEventAt == .distantPast, "a scan is not an event")
        #expect(session?.hasHookEvidence == false)
    }

    @Test("A discovered-only session is kept fresh by being found again, not by a fake event")
    func rediscoveryKeepsItAliveWithoutFakingAnEvent() {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        let found = DiscoveredSession(record: record(), identity: record().sessionIdentity(birth: 1))
        engine.apply(discovery: report([found]), at: clock.now)

        clock.advance(AttentionConfig.default.staleSessionSeconds + 3600)
        engine.apply(discovery: report([found]), at: clock.now)
        #expect(engine.sweep().dropReasons.isEmpty, "we can still see it, so it is not stale")
        #expect(engine.session("s1")?.lastEventAt == .distantPast, "and still no pretend event")
    }

    // MARK: - Refreshing what only the registry knows

    @Test("A later scan updates a discovered-only session's directory and title")
    func discoveredOnlyMetadataRefreshes() {
        // The session moved into a worktree after it was launched. With no hook to protect, the
        // newer scan is simply the better record — the old code only ever filled blanks, so the
        // launch directory would have stuck forever.
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)

        let first = record(cwd: "/Users/dev/code/atlas", title: "atlas")
        engine.apply(discovery: report([DiscoveredSession(record: first, identity: first.sessionIdentity(birth: 1))]), at: clock.now)
        #expect(engine.session("s1")?.identity.cwd == "/Users/dev/code/atlas")

        clock.advance(60)
        let moved = record(cwd: "/Users/dev/code/atlas/worktrees/sensitivity-train", title: "sensitivity train")
        engine.apply(discovery: report([DiscoveredSession(record: moved, identity: moved.sessionIdentity(birth: 1))]), at: clock.now)

        #expect(engine.session("s1")?.identity.cwd == "/Users/dev/code/atlas/worktrees/sensitivity-train")
        #expect(engine.session("s1")?.identity.title == "sensitivity train")
    }

    @Test("Once a hook has spoken, a later scan may still only fill blanks")
    func hookRemainsAuthoritativeAfterRefresh() {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse",
                                    identity: Fixture.identity(session: "s1", project: "from-hook")))

        clock.advance(60)
        let scan = record(cwd: "/Users/dev/code/from-registry")
        engine.apply(discovery: report([DiscoveredSession(record: scan, identity: scan.sessionIdentity(birth: 1))]), at: clock.now)

        #expect(engine.session("s1")?.identity.cwd == "/Users/dev/code/from-hook")
    }

    // MARK: - Uncertainty is not disappearance

    @Test("A session we were refused permission to inspect is not deleted")
    func perPidDenialDoesNotDelete() {
        // The scan as a whole worked; this one pid could not be checked. Absent from `verified` is
        // not the same as gone, and deleting it would quietly drop a live session.
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        let found = DiscoveredSession(record: record(), identity: record().sessionIdentity(birth: 1))
        engine.apply(discovery: report([found]), at: clock.now)

        clock.advance(30)
        engine.apply(discovery: report([], rejected: [
            RejectedRecord(sessionID: "s1", pid: 4242, verdict: .unverifiable),
        ]), at: clock.now)

        #expect(engine.session("s1") != nil, "undecided is not gone")
    }

    @Test("A session confirmed gone is still removed")
    func confirmedDeathStillRemoves() {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.apply(discovery: report([DiscoveredSession(record: record(), identity: record().sessionIdentity(birth: 1))]), at: clock.now)

        clock.advance(30)
        engine.apply(discovery: report([], rejected: [
            RejectedRecord(sessionID: "s1", pid: 4242, verdict: .processGone),
        ]), at: clock.now)

        #expect(engine.session("s1") == nil)
    }
}
