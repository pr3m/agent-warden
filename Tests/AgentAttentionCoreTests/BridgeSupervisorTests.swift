import Foundation
import Testing
@testable import AgentAttentionCore

/// A clock and a timer queue that only move when the test says so.
final class ManualSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)
    private var pending: [(at: Date, work: @Sendable () -> Void)] = []

    var schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void {
        { [self] delay, work in
            lock.lock(); pending.append((now.addingTimeInterval(delay), work)); lock.unlock()
        }
    }

    var clock: @Sendable () -> Date { { [self] in lock.lock(); defer { lock.unlock() }; return now } }

    /// Move time forward and run whatever fell due, in order.
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        now = now.addingTimeInterval(seconds)
        let due = pending.filter { $0.at <= now }.sorted { $0.at < $1.at }
        pending.removeAll { $0.at <= now }
        lock.unlock()
        due.forEach { $0.work() }
    }

    var nextDelay: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return pending.map { $0.at.timeIntervalSince(now) }.min()
    }
}

final class FakeHost: SupervisedProcess, @unchecked Sendable {
    let pid: Int32
    private let lock = NSLock()
    private var running = true
    private(set) var terminated = 0
    private(set) var killed = false
    var leavesOnTerminate = true
    let onExit: @Sendable (Int32) -> Void

    init(pid: Int32, onExit: @escaping @Sendable (Int32) -> Void) {
        self.pid = pid
        self.onExit = onExit
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func terminate() {
        lock.lock(); terminated += 1; let leave = leavesOnTerminate && running
        if leave { running = false }
        lock.unlock()
        if leave { onExit(0) }
    }

    func kill() {
        lock.lock(); killed = true; running = false; lock.unlock()
        onExit(9)
    }

    func crash(_ status: Int32 = 1) {
        lock.lock(); running = false; lock.unlock()
        onExit(status)
    }
}

final class FakeHostLauncher: SupervisedLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var hosts: [FakeHost] = []
    var exitImmediately: Int32?

    func launch(onExit: @escaping @Sendable (Int32) -> Void) throws -> SupervisedProcess {
        lock.lock()
        let host = FakeHost(pid: Int32(9000 + hosts.count), onExit: onExit)
        hosts.append(host)
        let immediate = exitImmediately
        lock.unlock()
        if let immediate { host.crash(immediate) }
        return host
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return hosts.count }
    var last: FakeHost? { lock.lock(); defer { lock.unlock() }; return hosts.last }
}

@Suite("Keeping the bridge host running")
struct BridgeSupervisorTests {
    /// Health checks are pushed far out unless a test is about them, so the restart timer is the
    /// only thing due.
    private func supervisor(_ launcher: FakeHostLauncher, _ time: ManualSchedule,
                            healthy: @escaping @Sendable () -> Bool = { true },
                            healthInterval: TimeInterval = 100_000) -> BridgeSupervisor {
        var policy = BridgeSupervisor.Policy()
        policy.healthInterval = healthInterval
        return BridgeSupervisor(launcher: launcher, healthCheck: healthy, policy: policy,
                                now: time.clock, schedule: time.schedule)
    }

    @Test("A host that crashes is restarted, after a backoff that grows and is capped")
    func crashRestartsWithBackoff() {
        let launcher = FakeHostLauncher(), time = ManualSchedule()
        let subject = supervisor(launcher, time)
        subject.start()
        #expect(subject.state == .running(pid: 9000))
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            launcher.last?.crash()
            // Health checks are scheduled too; the restart is the shortest wait.
            delays.append(time.nextDelay ?? -1)
            time.advance(time.nextDelay ?? 0)
        }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60])
        #expect(launcher.count == 9)
    }

    @Test("A host that stayed up for a minute starts the backoff again from the beginning")
    func healthyUptimeResetsBackoff() {
        let launcher = FakeHostLauncher(), time = ManualSchedule()
        let subject = supervisor(launcher, time)
        subject.start()
        launcher.last?.crash(); time.advance(1)
        launcher.last?.crash(); time.advance(2)
        time.advance(120)                                     // a long, healthy run
        launcher.last?.crash()
        #expect(time.nextDelay == 1)
    }

    @Test("A host that finds another one on the socket is left alone and asked about again later")
    func anotherHostIsNotACrash() {
        let launcher = FakeHostLauncher(), time = ManualSchedule()
        launcher.exitImmediately = BridgeSupervisor.hostAlreadyRunning
        let subject = supervisor(launcher, time)
        subject.start()
        #expect(subject.state == .externalHost)
        #expect(launcher.count == 1)
        time.advance(29)
        #expect(launcher.count == 1)
        time.advance(1)
        #expect(launcher.count == 2)
    }

    @Test("A host that stops answering is restarted after three missed health checks")
    func unhealthyHostIsRestarted() {
        let launcher = FakeHostLauncher(), time = ManualSchedule()
        final class Flag: @unchecked Sendable { var healthy = true }
        let flag = Flag()
        let subject = supervisor(launcher, time, healthy: { flag.healthy }, healthInterval: 30)
        subject.start()
        flag.healthy = false
        time.advance(30); time.advance(30)
        #expect(launcher.hosts[0].terminated == 0)
        time.advance(30)
        #expect(launcher.hosts[0].terminated == 1)
        time.advance(1)
        #expect(launcher.count == 2)
    }

    @Test("Stopping waits for the host to go, and nothing restarts it afterwards")
    func stopIsFinal() {
        let launcher = FakeHostLauncher(), time = ManualSchedule()
        let subject = supervisor(launcher, time)
        subject.start()
        #expect(subject.stop())
        #expect(subject.state == .stopped)
        #expect(launcher.hosts[0].terminated == 1 && launcher.hosts[0].killed == false)
        time.advance(600)
        #expect(launcher.count == 1)
    }

    @Test("A host that ignores the request to stop is forced only after the grace period")
    func stubbornHostIsForcedLast() {
        let launcher = FakeHostLauncher(), time = ManualSchedule()
        var policy = BridgeSupervisor.Policy()
        policy.stopGrace = 0.2
        let subject = BridgeSupervisor(launcher: launcher, healthCheck: { true }, policy: policy,
                                       now: time.clock, schedule: time.schedule)
        subject.start()
        launcher.last?.leavesOnTerminate = false
        #expect(subject.stop() == false)
        #expect(launcher.hosts[0].killed)
        time.advance(600)
        #expect(launcher.count == 1)
    }
}

@Suite("The MCP adapter")
struct MCPServerTests {
    private func call(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:],
                      id: Int = 1) -> [String: Any] {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let line = String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
        let reply = server.handle(line: line) ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]) ?? [:]
    }

    private func tool(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) -> [String: Any] {
        call(server, "tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any] ?? [:]
    }

    @Test("Initialising names the server and agrees a protocol version; notifications get no reply")
    func initialize() {
        let server = MCPServer(transport: { _ in BridgeResponse(ok: true) })
        let result = call(server, "initialize", ["protocolVersion": "2025-03-26"])["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2025-03-26")
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "agent-warden")
        let unknownVersion = call(server, "initialize", ["protocolVersion": "1999-01-01"])["result"] as? [String: Any]
        #expect(unknownVersion?["protocolVersion"] as? String == MCPServer.supportedVersions[0])
        #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect((call(server, "nope")["error"] as? [String: Any])?["code"] as? Int == -32601)
        let garbage = server.handle(line: "not json") ?? ""
        #expect(garbage.contains("-32700"))
    }

    @Test("A whole number cursor is taken, however the client spelled it")
    func wholeNumberCursorsAreAccepted() {
        var seen: [BridgeRequest] = []
        let server = MCPServer(transport: { request in seen.append(request); return BridgeResponse(ok: true) })
        for spelling in [12 as Any, 12.0 as Any, 1e1 as Any] {
            _ = tool(server, "warden_session_events", ["sessionId": "s1", "after": spelling])
        }
        #expect(seen.count == 3)
    }

    @Test("A cursor that is not a whole number is refused rather than replaying the session from zero")
    func brokenCursorIsRefused() {
        var seen: [BridgeRequest] = []
        let server = MCPServer(transport: { request in seen.append(request); return BridgeResponse(ok: true) })

        let fractional = tool(server, "warden_session_events", ["sessionId": "s1", "after": 12.7])
        #expect(fractional["isError"] as? Bool == true)

        let text = tool(server, "warden_session_events", ["sessionId": "s1", "after": "12"])
        #expect(text["isError"] as? Bool == true)

        // The point of the refusal: neither reached the host, where `0` means "every event ever".
        #expect(seen.isEmpty)
    }

    @Test("A broken message limit is refused too, rather than quietly becoming the default")
    func brokenMessageLimitIsRefused() {
        var seen: [BridgeRequest] = []
        let server = MCPServer(transport: { request in seen.append(request); return BridgeResponse(ok: true) })
        let result = tool(server, "warden_session_context", ["sessionId": "s1", "maxMessages": 3.5])
        #expect(result["isError"] as? Bool == true)
        #expect(seen.isEmpty)
    }

    @Test("Every operation is a tool; four change something and say so, and three of those need approval")
    func toolList() {
        let server = MCPServer(transport: { _ in BridgeResponse(ok: true) })
        let tools = (call(server, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == ["warden_list_sessions", "warden_session_status", "warden_session_events",
                          "warden_session_context", "warden_session_summary", "warden_focus_session",
                          "warden_start_session", "warden_send_prompt", "warden_adopt_session",
                          "warden_stop_session"])
        for tool in tools {
            let name = tool["name"] as! String
            let destructive = (tool["annotations"] as? [String: Any])?["destructiveHint"] as? Bool
            let required = (tool["inputSchema"] as? [String: Any])?["required"] as? [String] ?? []
            // Two different questions, deliberately not the same list. `start` spawns a real client
            // in a project directory and can exhaust the session cap, so a client that surfaces
            // destructive tools should surface it — but it carries no authorization field, because
            // nothing about it is the user's word to give.
            let changes = ["warden_start_session", "warden_send_prompt",
                           "warden_adopt_session", "warden_stop_session"].contains(name)
            let needsApproval = ["warden_send_prompt", "warden_adopt_session",
                                 "warden_stop_session"].contains(name)
            #expect(destructive == changes, "\(name)")
            #expect(required.contains("authorization") == needsApproval, "\(name)")
        }
    }

    @Test("A tool call without the user's approval reaches the host and is refused there, writing nothing")
    func unapprovedSendIsRefusedByTheHost() {
        let scratch = FileManager.default.temporaryDirectory.path
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let server = MCPServer(transport: host.handle, sleep: { _ in })
        let started = tool(server, "warden_start_session", ["requestId": "r1", "cwd": scratch])
        let id = ((started["structuredContent"] as? [String: Any])?["session"] as? [String: Any])?["sessionID"] as! String
        let refused = tool(server, "warden_send_prompt", ["sessionId": id, "messageId": "m1", "prompt": "go",
                                                          "authorization": ["confirmed": false, "statement": "go"]])
        #expect(refused["isError"] as? Bool == true)
        #expect((refused["structuredContent"] as? [String: Any])?["delivery"] as? String == "notSent")
        #expect(launcher.handle(id)?.writtenLines.isEmpty == true)
    }

    @Test("A send reports acknowledgement only once the client has echoed the message back")
    func sendWaitsForAcknowledgement() {
        let scratch = FileManager.default.temporaryDirectory.path
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        final class Polls: @unchecked Sendable { var count = 0 }
        let polls = Polls()
        let server = MCPServer(transport: host.handle, sleep: { _ in
            polls.count += 1
            // The client echoes on the second poll.
            if polls.count == 2, let line = launcher.handle(id)?.writtenLines.last { host.receive(line, for: id) }
        })
        let approved: [String: Any] = ["confirmed": true, "statement": "yes, send it"]
        let sent = tool(server, "warden_send_prompt", ["sessionId": id, "messageId": "m1", "prompt": "go",
                                                       "authorization": approved, "waitSeconds": 5])
        #expect((sent["structuredContent"] as? [String: Any])?["delivery"] as? String == "acknowledged")
        #expect(polls.count == 2)

        let quiet = tool(server, "warden_send_prompt", ["sessionId": id, "messageId": "m2", "prompt": "again",
                                                        "authorization": approved, "waitSeconds": 0])
        // The first turn is still in flight, so this one is refused as busy — never queued.
        #expect(quiet["isError"] as? Bool == true)
    }

    @Test("A cursor a client encodes as a whole-number float is read as that number")
    func wholeNumberFloatsAreIntegers() {
        final class Seen: @unchecked Sendable { var request: BridgeRequest? }
        let seen = Seen()
        let server = MCPServer(transport: { seen.request = $0; return BridgeResponse(ok: true) })
        _ = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"warden_session_events","arguments":{"sessionId":"S","after":42.0}}}"#)
        #expect(seen.request == .events(sessionID: "S", afterSequence: 42))
        _ = server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"warden_session_context","arguments":{"sessionId":"S","maxMessages":3.0}}}"#)
        #expect(seen.request == .context(sessionID: "S", maxMessages: 3))
    }

    @Test("The session list carries who controls each row")
    func controlOnEveryRow() {
        let observedID = "6c3d0000-0000-4000-8000-00000000cafe"
        let response = BridgeResponse(
            ok: true,
            sessions: [BridgeSessionState(sessionID: "OWNED-1", cwd: "/w/orbit-api", phase: .completed, startedAt: Date())],
            observed: [observedRow(observedID), observedRow("OWNED-1")],
            adoptions: [])
        let rows = MCPServer.controlList(response)
        #expect(rows.map { $0["control"] as? String } == ["owned", "observed"])
        #expect(rows.last?["sessionId"] as? String == observedID)
    }
}

@Suite("Settings that must fail in the safe direction")
struct BridgeSettingsFailClosedTests {
    private func settings(_ json: String) -> BridgeSettings {
        try! JSONCoding.decoder.decode(BridgeSettings.self, from: Data(json.utf8))
    }

    @Test("An absent enabled key leaves the bridge on, because nothing was said about it")
    func absentStaysOn() {
        #expect(settings(#"{"approvedRoots": []}"#).enabled)
    }

    @Test("A enabled key that is not a boolean turns the bridge off rather than on")
    func malformedFailsClosed() {
        #expect(!settings(#"{"enabled": "false"}"#).enabled)
        #expect(!settings(#"{"enabled": 0}"#).enabled)
        #expect(!settings(#"{"enabled": null}"#).enabled)
    }

    @Test("A boolean still means what it says")
    func booleansAreHonoured() {
        #expect(settings(#"{"enabled": true}"#).enabled)
        #expect(!settings(#"{"enabled": false}"#).enabled)
    }
}

@Suite("What the audit log remembers about reads")
struct BridgeAuditReadTests {
    private final class Spy: BridgeAuditRecording, @unchecked Sendable {
        var entries: [BridgeAuditEntry] = []
        func append(_ entry: BridgeAuditEntry) { entries.append(entry) }
    }

    @Test("Reading a session's conversation is recorded, because nothing else about it is")
    func contentReadsAreRecorded() {
        let spy = Spy()
        spy.record(request: .context(sessionID: "s1", maxMessages: 5),
                   response: BridgeResponse(ok: true), at: Date())
        spy.record(request: .summary(sessionID: "s2"), response: BridgeResponse(ok: true), at: Date())
        #expect(spy.entries.map(\.operation) == ["context", "summary"])
        #expect(spy.entries.map(\.sessionID) == ["s1", "s2"])
    }

    @Test("Nothing of what was read is written down")
    func contentIsNeverRecorded() {
        let spy = Spy()
        spy.record(request: .context(sessionID: "s1", maxMessages: 5),
                   response: BridgeResponse(ok: true), at: Date())
        #expect(spy.entries.first?.promptFingerprint == nil)
        #expect(spy.entries.first?.statement == nil)
    }

    @Test("Polling calls stay unrecorded, because they are noise rather than disclosure")
    func pollingStaysQuiet() {
        let spy = Spy()
        spy.record(request: .sessions, response: BridgeResponse(ok: true), at: Date())
        spy.record(request: .status(sessionID: "s1"), response: BridgeResponse(ok: true), at: Date())
        spy.record(request: .events(sessionID: "s1", afterSequence: 0),
                   response: BridgeResponse(ok: true), at: Date())
        #expect(spy.entries.isEmpty)
    }
}
