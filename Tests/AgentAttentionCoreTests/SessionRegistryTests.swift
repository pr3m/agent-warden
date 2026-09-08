import Foundation
import Testing
@testable import AgentAttentionCore

/// Discovering sessions that were already running before Agent Warden started.
///
/// The registry is Claude Code's own local bookkeeping, not a published API, so everything here is
/// defensive: only `*.json` is opened (the sibling `*.key` files are peer tokens and are never
/// touched, nor is `messagingSocketPath` ever connected to), records are size-capped, and anything
/// unparseable is skipped rather than guessed at.
///
/// The load-bearing rule is that a discovery is *not* an event. It tells us a session exists; it
/// says nothing about whether that session wants anything. Registry `status: busy` in particular is
/// stale by design and must never become an attention item, a "working" count or a stall.
@Suite("Session registry discovery")
final class SessionRegistryTests {
    private let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-warden-registry-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// The shape observed in Claude Code 2.1.26x, including the double-space day in `procStart`.
    @discardableResult
    private func writeRecord(
        name: String? = nil,
        sessionID: String,
        pid: Int32,
        procStart: String? = "Sun Sep  6 08:24:43 2026",
        cwd: String? = "/Users/dev/code/alpha",
        title: String? = "alpha work",
        status: String? = "busy",
        version: String? = "2.1.261",
        startedAtMillis: Int? = 1_788_683_084_362,
        updatedAtMillis: Int? = 1_788_683_085_232,
        extra: [String: Any] = [:]
    ) throws -> URL {
        var record: [String: Any] = [
            "sessionId": sessionID,
            "pid": Int(pid),
            "entrypoint": "cli",
            "kind": "interactive",
            "pidDomain": "local",
            "peerProtocol": 1,
            "peerFeatures": [],
            // Present in the real records; must never be opened or connected to.
            "messagingSocketPath": "/tmp/should-never-be-touched.sock",
            "nameSource": "derived",
            "nameSince": 1_788_683_084_000,
        ]
        if let procStart { record["procStart"] = procStart }
        if let cwd { record["cwd"] = cwd }
        if let title { record["name"] = title }
        if let status { record["status"] = status }
        if let version { record["version"] = version }
        if let startedAtMillis { record["startedAt"] = startedAtMillis }
        if let updatedAtMillis { record["updatedAt"] = updatedAtMillis }
        for (key, value) in extra { record[key] = value }

        let url = root.appendingPathComponent("sessions/\(name ?? "\(pid).abc").json")
        try JSONSerialization.data(withJSONObject: record).write(to: url)
        return url
    }

    private func probe(
        pid: Int32 = 4242,
        startedAt: Double,
        path: String = "/Users/dev/.local/share/claude/versions/2.1.261",
        available: Bool = true
    ) -> StubProcessIdentity {
        let stub = StubProcessIdentity(available: available)
        stub.add(pid: pid, startedAt: startedAt, command: "2.1.261", executablePath: path)
        return stub
    }

    /// The epoch seconds `procStart` above means, in whatever zone this machine runs in.
    private var procStartEpoch: Double {
        SessionRegistry.parseProcStart("Sun Sep  6 08:24:43 2026")!.timeIntervalSince1970
    }

    // MARK: - Verification

    @Test("A live process with a matching start time and a Claude executable is verified")
    func verifiedLiveSession() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242)
        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))

        #expect(report.verified.count == 1)
        let found = try #require(report.verified.first)
        #expect(found.record.sessionID == "sess-alpha")
        #expect(found.record.pid == 4242)
        #expect(found.record.title == "alpha work")
        #expect(found.record.status == "busy", "kept raw, and never interpreted")
        #expect(found.identity.cwd == "/Users/dev/code/alpha")
        #expect(found.identity.claudePID == 4242)
        #expect(found.identity.claudePIDStartedAt != nil)
    }

    @Test("A long session name survives the registry intact, all the way to the row")
    func longNameRoundTrips() throws {
        // Real names are worktree plus task and run well past 80 characters. Clipping in the parser
        // would make the full name unrecoverable in the panel and in Details, where the whole point
        // is that two similar worktrees can be told apart.
        let longName = "wundamental-exec-cashflow-truth-sensitivity-train — reconcile ledger against the plan and explain the variance"
        #expect(longName.count > 80)

        try writeRecord(sessionID: "sess-long", pid: 4242, title: longName)
        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))
        let found = try #require(report.verified.first)

        #expect(found.record.title == longName, "not truncated at 80")
        #expect(found.identity.title == longName)
        // The registry generated it (`nameSource: derived`), so it is kept in full for Details
        // rather than becoming the label — the worktree is the label.
        #expect(found.identity.generatedLabel == longName, "kept whole, for Details")
        #expect(found.identity.displayName == "alpha", "and the worktree is what the row shows")

        // And through discovery into the engine, which is what the UI actually reads.
        let engine = AttentionEngine(config: .default, clock: TestClock(Fixture.origin),
                                     liveness: StubLiveness(), restoring: nil)
        _ = engine.apply(discovery: report, at: Fixture.origin)
        #expect(engine.session("sess-long")?.identity.generatedLabel == longName)
    }

    @Test("An absurd name is still bounded, but far above any real one")
    func absurdNameIsBounded() throws {
        try writeRecord(sessionID: "sess-huge", pid: 4242, title: String(repeating: "x", count: 5_000))
        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))
        let title = try #require(report.verified.first?.record.title)
        #expect(title.count == 240, "a field from a file we do not control is still capped")
    }

    @Test("A record whose process is gone is rejected")
    func deadProcessRejected() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242)
        let empty = StubProcessIdentity(available: true)   // nothing registered: pid not found
        let report = SessionRegistry.scan(root: root, identity: empty)

        #expect(report.verified.isEmpty)
        #expect(report.rejected.map(\.verdict) == [.processGone])
    }

    @Test("A recycled pid — right number, wrong birth time — is rejected")
    func reusedPidRejected() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242)
        // Same pid, but the process was born an hour after the record claims.
        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch + 3600))

        #expect(report.verified.isEmpty)
        #expect(report.rejected.map(\.verdict) == [.startTimeMismatch])
    }

    @Test("A second of drift is tolerated; a minute is not")
    func startTimeTolerance() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242)
        // `procStart` has one-second resolution and is formatted in local time, so exact equality
        // with the kernel's microsecond birth time is not achievable.
        #expect(SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch + 1.4)).verified.count == 1)
        #expect(SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch - 1.4)).verified.count == 1)
        #expect(SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch + 60)).verified.isEmpty)
    }

    @Test("A live pid that is not a Claude executable is rejected")
    func wrongExecutableRejected() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242)
        let report = SessionRegistry.scan(
            root: root,
            identity: probe(startedAt: procStartEpoch, path: "/bin/zsh")
        )
        #expect(report.verified.isEmpty)
        #expect(report.rejected.map(\.verdict) == [.notClaude])
    }

    @Test("When process inspection is unavailable nothing is claimed either way")
    func inspectionUnavailable() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242)
        let report = SessionRegistry.scan(root: root, identity: StubProcessIdentity(available: false))

        #expect(report.verified.isEmpty, "unverified is not the same as present")
        #expect(report.rejected.map(\.verdict) == [.unverifiable])
        #expect(report.inspectionAvailable == false)
    }

    @Test("A procStart rendered in UTC verifies on a machine that is not")
    func procStartRenderedInUTC() throws {
        // The bug this exists to prevent: observed records render `procStart` in UTC while `ps`
        // renders local. On a machine at UTC+3 a naive local parse is wrong by exactly three hours
        // and rejects every live session on the box.
        try writeRecord(sessionID: "sess-alpha", pid: 4242, startedAtMillis: nil)
        let asUTC = procStartEpoch
        let offset = Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: asUTC)))

        #expect(SessionRegistry.scan(root: root, identity: probe(startedAt: asUTC)).verified.count == 1,
                "the UTC reading")
        #expect(SessionRegistry.scan(root: root, identity: probe(startedAt: asUTC - offset)).verified.count == 1,
                "and the local reading of the same string")
    }

    @Test("Without a usable procStart, the millisecond epoch verifies instead")
    func startedAtFallback() throws {
        let birth = Date().timeIntervalSince1970
        // `startedAt` is stamped just after the exec, so a few seconds later is normal.
        try writeRecord(sessionID: "sess-alpha", pid: 4242, procStart: nil,
                        startedAtMillis: Int((birth + 3) * 1000))
        #expect(SessionRegistry.scan(root: root, identity: probe(startedAt: birth)).verified.count == 1)

        // A different session claiming the same pid, stamped ten minutes before that process was
        // born: not the same process, however plausible the pid looks.
        try writeRecord(name: "stale", sessionID: "sess-stale", pid: 4242, procStart: nil,
                        startedAtMillis: Int((birth - 600) * 1000))
        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: birth))
        #expect(report.verified.map(\.record.sessionID) == ["sess-alpha"])
        #expect(report.rejected.map(\.verdict) == [.startTimeMismatch])
    }

    @Test("With neither a start time nor an epoch, nothing is claimed")
    func noBirthEvidence() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242, procStart: nil, startedAtMillis: nil)
        #expect(SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch)).rejected
            .map(\.verdict) == [.unverifiable])
    }

    @Test("A pid recycled hours later is still rejected under either reading")
    func recycledPidStillRejected() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242, startedAtMillis: nil)
        // Neither the UTC nor the local reading of the record lands near this birth time.
        #expect(SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch + 86_400)).verified.isEmpty)
        #expect(SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch - 86_400)).verified.isEmpty)
    }

    @Test("The double-space day in the real format parses, and a broken one does not")
    func procStartParsing() {
        #expect(SessionRegistry.parseProcStart("Sun Sep  6 08:24:43 2026") != nil)
        #expect(SessionRegistry.parseProcStart("Sat Sep 15 19:52:21 2026") != nil)
        #expect(SessionRegistry.parseProcStart("not a date") == nil)
        #expect(SessionRegistry.parseProcStart("") == nil)
    }

    // MARK: - Reading the directory

    @Test("Only .json is opened; peer token files are never touched")
    func onlyJSONIsRead() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242)
        // A peer token sitting next to it. Opening this would be a security problem, so the scan
        // must not even consider it.
        let key = root.appendingPathComponent("sessions/4242.abc.key")
        try Data("SECRET-PEER-TOKEN".utf8).write(to: key)

        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))
        #expect(report.filesConsidered == 1, "the .key file is not even a candidate")
        #expect(report.verified.count == 1)
        #expect(FileManager.default.contents(atPath: key.path) == Data("SECRET-PEER-TOKEN".utf8),
                "and it is certainly not modified")
    }

    @Test("Scanning never writes anything")
    func scanIsReadOnly() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path).sorted()
        let stamps = try before.map { name -> Date in
            let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("sessions/\(name)").path)
            return attrs[.modificationDate] as! Date
        }

        _ = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))
        _ = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))

        let after = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path).sorted()
        #expect(after == before)
        for (index, name) in after.enumerated() {
            let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("sessions/\(name)").path)
            #expect((attrs[.modificationDate] as! Date) == stamps[index])
        }
    }

    @Test("Malformed and empty records are counted and skipped")
    func malformedRecords() throws {
        try writeRecord(sessionID: "sess-good", pid: 4242)
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("sessions/broken.json"))
        try Data("[]".utf8).write(to: root.appendingPathComponent("sessions/array.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("sessions/empty.json"))
        try Data(#"{"pid": 1}"#.utf8).write(to: root.appendingPathComponent("sessions/nosession.json"))

        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))
        #expect(report.verified.count == 1)
        #expect(report.malformed == 4)
    }

    @Test("An implausibly large record is skipped rather than read into memory")
    func oversizedRecord() throws {
        try writeRecord(sessionID: "sess-good", pid: 4242)
        let huge = root.appendingPathComponent("sessions/huge.json")
        try Data(repeating: 0x20, count: SessionRegistry.maximumRecordBytes + 1).write(to: huge)

        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))
        #expect(report.oversized == 1)
        #expect(report.verified.count == 1)
    }

    @Test("An unknown or older schema degrades instead of failing")
    func unknownSchema() throws {
        // Only sessionId, pid and procStart are required; everything else is optional, and unknown
        // keys are ignored. This is somebody else's file format and it will change.
        try writeRecord(sessionID: "sess-alpha", pid: 4242, cwd: nil, title: nil,
                        status: nil, version: nil, startedAtMillis: nil, updatedAtMillis: nil,
                        extra: ["somethingNewInTheFuture": ["a": 1]])
        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))

        #expect(report.verified.count == 1)
        let found = try #require(report.verified.first)
        #expect(found.record.cwd == nil)
        #expect(found.record.status == nil)
        #expect(found.identity.cwd.isEmpty)
    }

    @Test("A missing registry directory is not an error")
    func absentRegistry() {
        let nowhere = root.appendingPathComponent("does-not-exist")
        let report = SessionRegistry.scan(root: nowhere, identity: probe(startedAt: procStartEpoch))
        #expect(report.registryPresent == false)
        #expect(report.verified.isEmpty)
        #expect(report.malformed == 0)
    }

    @Test("Two records for one session collapse to the freshest")
    func duplicateSessionRecords() throws {
        try writeRecord(name: "old", sessionID: "sess-alpha", pid: 4242,
                        cwd: "/Users/dev/code/old", updatedAtMillis: 1_788_683_000_000)
        try writeRecord(name: "new", sessionID: "sess-alpha", pid: 4242,
                        cwd: "/Users/dev/code/new", updatedAtMillis: 1_788_683_999_000)

        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))
        #expect(report.verified.count == 1)
        #expect(report.verified.first?.identity.cwd == "/Users/dev/code/new")
    }

    @Test("The pid in the filename is never trusted over the record")
    func filenamePidIgnored() throws {
        // A stale or renamed file must not be able to point verification at a different process.
        try writeRecord(name: "99999.stale", sessionID: "sess-alpha", pid: 4242)
        let report = SessionRegistry.scan(root: root, identity: probe(pid: 4242, startedAt: procStartEpoch))
        #expect(report.verified.first?.record.pid == 4242)
    }

    @Test("The messaging socket path is read but never used to connect")
    func socketPathNotUsed() throws {
        try writeRecord(sessionID: "sess-alpha", pid: 4242)
        let report = SessionRegistry.scan(root: root, identity: probe(startedAt: procStartEpoch))
        let identity = try #require(report.verified.first?.identity)
        // Nothing in the identity we build carries it forward, so nothing downstream can dial it.
        let encoded = try String(data: JSONCoding.encoder.encode(identity), encoding: .utf8) ?? ""
        #expect(!encoded.contains("should-never-be-touched"))
        #expect(!encoded.contains(".sock"))
    }
}
