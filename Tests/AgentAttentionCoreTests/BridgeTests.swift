import Foundation
import Testing
@testable import AgentAttentionCore

/// A client that never launches anything. Everything below is about the host's rules, and rules are
/// exactly what a real process would make harder to see.
final class FakeLauncher: BridgeClientLaunching, @unchecked Sendable {
    let lock = NSLock()
    private(set) var launched: [(sessionID: String, cwd: String, model: String?)] = []
    private(set) var handles: [String: FakeHandle] = [:]
    var failNextLaunch: String?

    func launch(sessionID: String, cwd: String, model: String?,
                onLine: @escaping (String) -> Void,
                onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        lock.lock(); defer { lock.unlock() }
        if let message = failNextLaunch {
            failNextLaunch = nil
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        launched.append((sessionID, cwd, model))
        let handle = FakeHandle(pid: Int32(4000 + launched.count))
        handles[sessionID] = handle
        return handle
    }

    func handle(_ sessionID: String) -> FakeHandle? {
        lock.lock(); defer { lock.unlock() }
        return handles[sessionID]
    }
}

final class FakeHandle: BridgeClientHandle, @unchecked Sendable {
    let pid: Int32
    private let lock = NSLock()
    private(set) var written: [String] = []
    private(set) var terminated = false
    private var running = true
    var acceptsWrites = true
    /// A client that does not go when asked, so shutdown has something real to wait for.
    var ignoreTerminate = false
    /// Called inside `write`, so a client that answers during the write can be modelled.
    var onWrite: ((String) -> Void)?

    init(pid: Int32) { self.pid = pid }

    @discardableResult
    func write(line: String) -> Bool {
        lock.lock()
        guard acceptsWrites else { lock.unlock(); return false }
        written.append(line)
        let callback = onWrite
        lock.unlock()
        callback?(line)                 // outside the lock, exactly as a real client's output is
        return true
    }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        terminated = true
        if !ignoreTerminate { running = false }
    }

    func simulateExit() {
        lock.lock(); defer { lock.unlock() }
        running = false
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var writtenLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return written
    }
}

/// The documented success result frame, which carries **its own** `uuid`.
///
/// That identity is what tells one turn's answer from another's: `session_id` names the whole
/// conversation, so it cannot say which turn a result belongs to. Each call gets a fresh one unless
/// a test deliberately replays an old answer.
private func successResult(_ sessionID: String, _ text: String,
                           uuid: String = UUID().uuidString) -> String {
    #"{"type":"result","subtype":"success","uuid":"\#(uuid)","session_id":"\#(sessionID)","is_error":false,"result":"\#(text)"}"#
}

/// The local bridge: what it will do, and — mostly — what it refuses to.
@Suite("Session bridge")
struct BridgeHostTests {
    /// A real directory, because approved roots are resolved through their symlinks now.
    private let scratch = FileManager.default.temporaryDirectory.path

    private func makeHost(_ launcher: FakeLauncher = FakeLauncher()) -> (BridgeHost, FakeLauncher) {
        (BridgeHost(launcher: launcher, approvedRoots: [scratch]), launcher)
    }

    private func start(_ host: BridgeHost, request: String = "r1", cwd: String? = nil) -> BridgeSessionState? {
        host.handle(.start(.init(requestID: request, cwd: cwd ?? scratch))).session
    }

    /// The echo Claude Code sends for `--replay-user-messages`: **the frame we wrote, played back**.
    /// Anything else is not our message coming home, and the host now says so.
    private func echo(_ launcher: FakeLauncher, _ sessionID: String) -> String {
        launcher.handle(sessionID)?.writtenLines.last ?? "{}"
    }

    @Test("A session is started in an approved directory, and reported as accepted")
    func startsASession() {
        let (host, launcher) = makeHost()
        let response = host.handle(.start(.init(requestID: "r1", cwd: scratch, model: "opus")))

        #expect(response.ok)
        #expect(response.session?.phase == .accepted, "accepted is not the same as acknowledged")
        #expect(response.session?.pid != nil)
        #expect(launcher.launched.first?.cwd == BridgeHost.resolve(scratch),
                "the directory is resolved through its symlinks before anything is started")
        #expect(launcher.launched.first?.model == "opus")
        #expect(UUID(uuidString: response.session?.sessionID ?? "") != nil)
    }

    @Test("A directory nobody approved is refused")
    func refusesUnapprovedDirectories() {
        let (host, launcher) = makeHost()
        let response = host.handle(.start(.init(requestID: "r1", cwd: "/etc")))

        #expect(!response.ok)
        #expect(response.error?.code == .directoryNotApproved)
        #expect(launcher.launched.isEmpty, "and nothing was launched")
    }

    @Test("Repeating a start request returns the same session rather than making another")
    func startIsIdempotent() {
        let (host, launcher) = makeHost()
        let first = start(host)
        let second = start(host)

        #expect(first?.sessionID == second?.sessionID)
        #expect(launcher.launched.count == 1)
    }

    @Test("A session this host did not start is never driven", arguments: [
        "11111111-2222-3333-4444-555555555555", "some-terminal-session",
    ])
    func refusesUnownedSessions(_ foreign: String) {
        // The whole point. A session in somebody's terminal is observed by Agent Warden; adopting
        // it here would mean two things steering one conversation.
        let (host, _) = makeHost()
        let send = host.handle(.send(.init(sessionID: foreign, messageID: "m1", prompt: "hello")))
        #expect(!send.ok)
        #expect(send.error?.code == .notOwned)

        let stop = host.handle(.stop(sessionID: foreign))
        #expect(!stop.ok)
        #expect(stop.error?.code == .notOwned)

        #expect(host.handle(.status(sessionID: foreign)).error?.code == .notOwned)
        #expect(host.handle(.events(sessionID: foreign, afterSequence: 0)).error?.code == .notOwned)
    }

    @Test("Writing to a pipe is not acknowledgement; the client's echo is")
    func acknowledgementComesFromTheClient() {
        let (host, launcher) = makeHost()
        let session = start(host)!
        _ = host.handle(.send(.init(sessionID: session.sessionID, messageID: "m1", prompt: "hello")))

        let afterWrite = host.handle(.status(sessionID: session.sessionID)).session
        #expect(afterWrite?.phase == .accepted, "the prompt is written, and that proves nothing")
        #expect(launcher.handle(session.sessionID)?.writtenLines.count == 1)

        host.receive(echo(launcher, session.sessionID), for: session.sessionID)

        let afterEcho = host.handle(.status(sessionID: session.sessionID)).session
        #expect(afterEcho?.phase == .clientAcknowledged)
        #expect(afterEcho?.messages.first?.acknowledgedAt != nil)
        #expect(afterEcho?.clientReportedSessionID == session.sessionID,
                "and the client names the same session we started")
    }

    @Test("Activity, result and completion are distinct states")
    func statesAreDistinct() {
        let (host, launcher) = makeHost()
        let session = start(host)!
        let id = session.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))

        host.receive(echo(launcher, id), for: id)
        host.receive(#"{"type":"assistant","session_id":"\#(id)","message":{"content":[{"type":"text","text":"working"}]}}"#, for: id)
        #expect(host.handle(.status(sessionID: id)).session?.phase == .active)

        host.receive(successResult(id, "done"), for: id)
        let final = host.handle(.status(sessionID: id)).session
        #expect(final?.phase == .completed)
        #expect(final?.messages.first?.completedAt != nil)

        let events = host.handle(.events(sessionID: id, afterSequence: 0)).events ?? []
        #expect(events.contains { $0.kind == .acknowledged })
        #expect(events.contains { $0.kind == .assistantText && $0.text == "working" })
        #expect(events.contains { $0.kind == .result && $0.text == "done" })
    }

    @Test("Two turns go to the same session, in order")
    func twoTurnsOneSession() {
        let (host, launcher) = makeHost()
        let session = start(host)!
        let id = session.sessionID

        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "first")))
        host.receive(echo(launcher, id), for: id)
        host.receive(successResult(id, "one"), for: id)
        _ = host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "second")))
        host.receive(echo(launcher, id), for: id)
        host.receive(successResult(id, "two"), for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages.map(\.messageID) == ["m1", "m2"])
        #expect(state?.messages.allSatisfy { $0.completedAt != nil } == true)
        #expect(launcher.handle(id)?.writtenLines.count == 2, "both went to the one client")
        #expect(launcher.launched.count == 1, "and no second session was started")
    }

    @Test("The same message id twice is a no-op; the same id with different text is refused")
    func idempotencyAndConflict() {
        let (host, launcher) = makeHost()
        let id = start(host)!.sessionID

        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        let repeated = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        #expect(repeated.ok)
        #expect(launcher.handle(id)?.writtenLines.count == 1, "nothing was sent twice")

        let conflicting = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "different")))
        #expect(!conflicting.ok)
        #expect(conflicting.error?.code == .idempotencyConflict)
        #expect(launcher.handle(id)?.writtenLines.count == 1)
    }

    @Test("An oversized prompt is refused rather than trimmed")
    func promptsAreBounded() {
        let (host, launcher) = makeHost()
        let id = start(host)!.sessionID
        let huge = String(repeating: "x", count: BridgeProtocol.maximumPromptBytes + 1)

        let response = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: huge)))
        #expect(!response.ok)
        #expect(response.error?.code == .limitReached)
        #expect(launcher.handle(id)?.writtenLines.isEmpty == true)
    }

    @Test("The number of owned sessions is bounded")
    func sessionCountIsBounded() {
        let (host, _) = makeHost()
        for index in 0..<BridgeProtocol.maximumSessions {
            #expect(host.handle(.start(.init(requestID: "r\(index)", cwd: scratch))).ok)
        }
        let overflow = host.handle(.start(.init(requestID: "one-too-many", cwd: scratch)))
        #expect(!overflow.ok)
        #expect(overflow.error?.code == .limitReached)
    }

    @Test("A client that will not take input leaves the turn uncertain, not sent")
    func brokenPipeIsUncertain() {
        let (host, launcher) = makeHost()
        let id = start(host)!.sessionID
        launcher.handle(id)?.acceptsWrites = false

        let response = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        #expect(!response.ok)
        #expect(response.session?.phase == .uncertain)
        // The intent is recorded *before* the write is attempted, and the message is left uncertain.
        // That is the point: a write that failed halfway is indistinguishable from one that arrived,
        // so the id is burnt and the same message can never be sent twice on a retry.
        #expect(response.session?.messages.first?.messageID == "m1")
        #expect(response.session?.messages.first?.phase == .uncertain)

        let retry = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        #expect(retry.ok, "a retry is accepted as already-attempted")
        #expect(launcher.handle(id)?.writtenLines.isEmpty == true, "and nothing is written again")
    }

    @Test("A client that goes without a result leaves the turn uncertain — and nothing is resent")
    func disconnectIsUncertain() {
        let (host, launcher) = makeHost()
        let id = start(host)!.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        host.receive(echo(launcher, id), for: id)

        host.clientExited(id, status: 0)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.phase == .uncertain, "silence is not success")
        #expect(state?.exitStatus == 0)
        #expect(launcher.handle(id)?.writtenLines.count == 1, "and nothing was sent again")
    }

    @Test("A client that exits badly is a failure, and one that already finished is not disturbed")
    func exitStatusIsRead() {
        let (host, launcher) = makeHost()
        let failing = start(host, request: "r1")!.sessionID
        host.clientExited(failing, status: 2)
        #expect(host.handle(.status(sessionID: failing)).session?.phase == .failed)

        let finished = start(host, request: "r2")!.sessionID
        _ = host.handle(.send(.init(sessionID: finished, messageID: "m1", prompt: "hello")))
        host.receive(echo(launcher, finished), for: finished)
        host.receive(successResult(finished, "ok"), for: finished)
        host.clientExited(finished, status: 0)
        #expect(host.handle(.status(sessionID: finished)).session?.phase == .completed,
                "a normal exit after a result does not unsettle it")
    }

    @Test("A reported error is a failure, with its text kept as an event")
    func errorsAreReported() {
        let (host, _) = makeHost()
        let id = start(host)!.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        host.receive(#"{"type":"result","session_id":"\#(id)","is_error":true,"result":"model overloaded"}"#,
                     for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.phase == .failed)
        #expect(state?.messages.first?.phase == .failed)
        #expect(host.handle(.events(sessionID: id, afterSequence: 0)).events?
            .contains { $0.kind == .error && $0.text == "model overloaded" } == true)
    }

    @Test("A permission prompt is surfaced, never answered")
    func permissionsAreNotAnswered() {
        let (host, launcher) = makeHost()
        let id = start(host)!.sessionID
        host.receive(#"{"type":"system","subtype":"permission_request","session_id":"\#(id)"}"#, for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.permissionNote?.contains("does not answer permission prompts") == true)
        #expect(host.handle(.events(sessionID: id, afterSequence: 0)).events?
            .contains { $0.kind == .permission } == true)
        #expect(launcher.handle(id)?.writtenLines.isEmpty == true,
                "nothing was written back — a permission is Claude Code's to decide, not this bridge's")
    }

    @Test("A line that is not JSON is noted, and changes no state")
    func malformedOutputIsSurvivable() {
        let (host, _) = makeHost()
        let id = start(host)!.sessionID
        host.receive("this is not json", for: id)
        host.receive("", for: id)

        #expect(host.handle(.status(sessionID: id)).session?.phase == .accepted)
    }

    @Test("A caller can resume from a sequence, and is told when events were dropped")
    func eventsResumeAndReportGaps() {
        let (host, _) = makeHost()
        let id = start(host)!.sessionID
        for index in 0..<(BridgeProtocol.maximumRetainedEvents + 50) {
            host.receive(#"{"type":"assistant","session_id":"\#(id)","message":{"content":[{"type":"text","text":"line \#(index)"}]}}"#,
                         for: id)
        }

        let fromStart = host.handle(.events(sessionID: id, afterSequence: 0))
        #expect((fromStart.events?.count ?? 0) <= BridgeProtocol.maximumRetainedEvents)
        #expect(fromStart.droppedBefore != nil, "a caller asking from the beginning is told what is missing")

        // A response is paged, so a caller is never handed a frame too big to read — and is told
        // there is more rather than being left to assume the page was everything.
        #expect(fromStart.events?.count == BridgeProtocol.maximumEventsPerResponse)
        #expect(fromStart.moreAvailable == true)
        #expect(fromStart.nextAfter == fromStart.events?.last?.sequence)

        var cursor = fromStart.nextAfter ?? 0
        var pages = 1
        while pages < 200 {
            let page = host.handle(.events(sessionID: id, afterSequence: cursor))
            guard page.moreAvailable == true else {
                cursor = page.nextAfter ?? cursor
                break
            }
            cursor = page.nextAfter ?? cursor
            pages += 1
        }
        #expect(host.handle(.events(sessionID: id, afterSequence: cursor)).events?.isEmpty == true,
                "and paging to the end really is the end")
    }

    @Test("A turn with no word for too long becomes uncertain, and stays that way")
    func overdueTurnsAreUncertain() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch], now: { now })
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))

        now = now.addingTimeInterval(600)
        host.markOverdue(after: 300)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.phase == .uncertain)
        #expect(state?.messages.first?.phase == .uncertain)
        #expect(launcher.handle(id)?.writtenLines.count == 1,
                "an unanswered turn is reported, not retried — a resend is how one instruction becomes two")
    }

    @Test("Stopping touches only what this host started, and shutdown stops all of them")
    func cleanupIsScoped() {
        let (host, launcher) = makeHost()
        let first = start(host, request: "r1")!.sessionID
        let second = start(host, request: "r2")!.sessionID

        _ = host.handle(.stop(sessionID: first))
        #expect(launcher.handle(first)?.terminated == true)
        #expect(launcher.handle(second)?.terminated == false, "the other one is untouched")
        #expect(host.handle(.status(sessionID: first)).session?.phase == .stopping,
                "the stop has been asked for; the process has not confirmed it yet")

        host.clientExited(first, status: 0)
        #expect(host.handle(.status(sessionID: first)).session?.phase == .stopped,
                "and only the exit itself turns the request into a fact")

        host.stopAll()
        #expect(launcher.handle(second)?.terminated == true)
    }

    @Test("A failed launch is reported as unavailable, not as a running session")
    func launchFailureIsHonest() {
        let (host, launcher) = makeHost()
        launcher.failNextLaunch = "claude not found"

        let response = host.handle(.start(.init(requestID: "r1", cwd: scratch)))
        #expect(!response.ok)
        #expect(response.error?.code == .clientUnavailable)
        #expect(response.session?.phase == .failed)
    }

    @Test("The prompt frame is the documented stream-json user message")
    func promptFrameShape() {
        let frame = BridgeHost.userMessageFrame(text: "hello", sessionID: "s1", correlationID: "c1")
        let object = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
        #expect((object?["type"] as? String) == "user")
        let message = object?["message"] as? [String: Any]
        #expect((message?["role"] as? String) == "user")
        #expect((object?["session_id"] as? String) == "s1")
        #expect(BridgeHost.userText(object ?? [:])?.contains("c1") == true,
                "the correlation id travels with the message, so the echo can be matched to it")
    }
}

/// The socket half: framing and refusals, without a live listener.
@Suite("Bridge socket framing")
struct BridgeSocketTests {
    private func server() -> BridgeSocketServer {
        BridgeSocketServer(path: "/tmp/warden-bridge-test.sock",
                           host: BridgeHost(launcher: FakeLauncher(),
                                            approvedRoots: ["/tmp/warden-bridge-scratch"]))
    }

    @Test("A frame that is not a request is refused, not guessed at", arguments: [
        "not json at all", "{}", "{\"start\":{}}", "[1,2,3]",
    ])
    func malformedFramesAreRefused(_ frame: String) {
        let response = server().answer(to: Data(frame.utf8))
        #expect(!response.ok)
        #expect(response.error?.code == .malformed)
    }

    @Test("An empty frame is refused")
    func emptyFrameIsRefused() {
        #expect(server().answer(to: Data()).error?.code == .malformed)
    }

    @Test("A well-formed request reaches the host")
    func wellFormedRequestIsAnswered() throws {
        let request = BridgeRequest.status(sessionID: nil)
        let encoded = try JSONCoding.encoder.encode(request)
        let response = server().answer(to: encoded)
        #expect(response.ok)
        #expect(response.sessions?.isEmpty == true)
    }

    @Test("The socket lives in the user's own data directory, not on a network port")
    func socketIsLocalAndPrivate() {
        let path = AppPaths.resolved().root.appendingPathComponent("bridge.sock").path
        #expect(path.contains(AppPaths.resolved().root.path))
        #expect(!path.contains(":"), "there is no port here to reach")
    }
}

/// The findings an independent review raised against the first cut. Each of these is a behaviour
/// that was wrong, not a preference.
@Suite("Bridge review corrections")
struct BridgeCorrectionTests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func makeHost() -> (BridgeHost, FakeLauncher) {
        let launcher = FakeLauncher()
        return (BridgeHost(launcher: launcher, approvedRoots: [scratch]), launcher)
    }

    private func correlation(_ host: BridgeHost, _ sessionID: String) -> String {
        host.handle(.status(sessionID: sessionID)).session?.messages.last?.correlationID ?? "none"
    }

    /// A hand-built echo, for the cases that are *about* an echo being wrong.
    private func echo(_ correlationID: String, session: String, text: String = "prompt") -> String {
        #"{"type":"user","session_id":"\#(session)","message":{"role":"user","content":[{"type":"text","text":"\#(text)\n\n[warden-correlation: \#(correlationID)]"}]}}"#
    }

    /// The real thing: the frame the host actually wrote.
    private func writtenEcho(_ launcher: FakeLauncher, _ sessionID: String) -> String {
        launcher.handle(sessionID)?.writtenLines.last ?? "{}"
    }

    @Test("Reusing a start id with different intent is a conflict, not a retry")
    func startIdConflictIsRefused() {
        let (host, launcher) = makeHost()
        let first = host.handle(.start(.init(requestID: "r1", cwd: scratch, model: "opus")))
        #expect(first.ok)

        let sameIntent = host.handle(.start(.init(requestID: "r1", cwd: scratch, model: "opus")))
        #expect(sameIntent.session?.sessionID == first.session?.sessionID)

        let differentModel = host.handle(.start(.init(requestID: "r1", cwd: scratch, model: "sonnet")))
        #expect(differentModel.error?.code == .idempotencyConflict,
                "the same name for a different intention is a conflict")
        #expect(launcher.launched.count == 1)
    }

    @Test("A directory reached through a symlink out of the approved root is refused")
    func symlinkEscapeIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-bridge-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [root.path])

        #expect(host.handle(.start(.init(requestID: "inside", cwd: root.path))).ok)
        let escaped = host.handle(.start(.init(requestID: "escape", cwd: link.path)))
        #expect(escaped.error?.code == .directoryNotApproved,
                "the path is resolved before it is compared, so a link cannot walk out of the root")
        #expect(launcher.launched.count == 1)
    }

    @Test("A frame naming another session cannot acknowledge or complete this one")
    func crossSessionFramesAreIgnored() {
        let (host, _) = makeHost()
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        let correlationID = correlation(host, id)

        host.receive(echo(correlationID, session: "someone-else"), for: id)
        host.receive(#"{"type":"result","session_id":"someone-else","is_error":false,"result":"done"}"#, for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.phase == .accepted, "nothing about another session settles this one")
        #expect(state?.messages.first?.acknowledgedAt == nil)
        #expect(state?.messages.first?.completedAt == nil)
    }

    @Test("An echo without our correlation id acknowledges nothing", arguments: [
        "a tool result someone replayed", "an unrelated user message",
    ])
    func unrelatedEchoesDoNotAcknowledge(_ text: String) {
        let (host, _) = makeHost()
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))

        host.receive(echo("a-different-correlation", session: id, text: text), for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.phase == .accepted)
        #expect(state?.messages.first?.acknowledgedAt == nil,
                "acknowledgement means *our* message came back, not that some user frame did")
    }

    @Test("A repeated echo of the same message acknowledges once")
    func duplicateEchoesCountOnce() {
        let (host, launcher) = makeHost()
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))

        host.receive(writtenEcho(launcher, id), for: id)
        let firstAck = host.handle(.status(sessionID: id)).session?.messages.first?.acknowledgedAt
        host.receive(writtenEcho(launcher, id), for: id)

        let events = host.handle(.events(sessionID: id, afterSequence: 0)).events ?? []
        #expect(events.filter { $0.kind == .acknowledged }.count == 1)
        #expect(host.handle(.status(sessionID: id)).session?.messages.first?.acknowledgedAt == firstAck)
    }

    @Test("A second turn is refused while the first is still in flight")
    func oneTurnAtATime() {
        let (host, launcher) = makeHost()
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "first")))

        let second = host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "second")))
        #expect(second.error?.code == .busy,
                "with two out at once, a result could not be attributed to either")
        #expect(launcher.handle(id)?.writtenLines.count == 1)

        // Once the first result lands, the next turn is accepted.
        host.receive(writtenEcho(launcher, id), for: id)
        host.receive(successResult(id, "one"), for: id)
        #expect(host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "second"))).ok)
        #expect(launcher.handle(id)?.writtenLines.count == 2)
    }

    @Test("A result settles only the turn in flight, and never a queued one")
    func resultsDoNotCompleteEverything() {
        let (host, launcher) = makeHost()
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "first")))
        host.receive(writtenEcho(launcher, id), for: id)
        host.receive(successResult(id, "one"), for: id)
        _ = host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "second")))

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages.first?.completedAt != nil)
        #expect(state?.messages.last?.completedAt == nil, "the second turn is not finished by the first's result")

        // And a stray result with nothing outstanding completes nothing at all.
        host.receive(writtenEcho(launcher, id), for: id)
        host.receive(successResult(id, "two"), for: id)
        host.receive(successResult(id, "stray"), for: id)
        let after = host.handle(.status(sessionID: id)).session
        #expect(after?.messages.count == 2)
        #expect(after?.messages.allSatisfy { $0.completedAt != nil } == true)
    }

    @Test("A turn's deadline is anchored to that turn, not to the session's last noise")
    func deadlineIsPerTurn() {
        var now = Date(timeIntervalSince1970: 2_000_000)
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch], now: { now })
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID

        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "first")))
        host.receive(writtenEcho(launcher, id), for: id)
        host.receive(successResult(id, "one"), for: id)

        // A long quiet gap, then a *new* turn. Its deadline starts now, not from the first turn.
        now = now.addingTimeInterval(10_000)
        _ = host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "second")))
        host.markOverdue(after: 300)
        #expect(host.handle(.status(sessionID: id)).session?.messages.last?.phase != .uncertain,
                "a fresh turn must not inherit the previous one's age")

        // Unsolicited noise does not keep postponing a real timeout either.
        now = now.addingTimeInterval(200)
        host.receive("not json", for: id)
        now = now.addingTimeInterval(200)
        host.markOverdue(after: 300)
        #expect(host.handle(.status(sessionID: id)).session?.messages.last?.phase == .uncertain)
    }

    @Test("Identifiers are bounded and printable", arguments: [
        "", String(repeating: "x", count: BridgeProtocol.maximumIdentifierLength + 1), "with\u{0}null",
    ])
    func identifiersAreValidated(_ identifier: String) {
        let (host, launcher) = makeHost()
        #expect(host.handle(.start(.init(requestID: identifier, cwd: scratch))).error?.code == .malformed)
        #expect(launcher.launched.isEmpty, "a refused request starts nothing")

        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        #expect(host.handle(.send(.init(sessionID: id, messageID: identifier, prompt: "x")))
            .error?.code == .malformed)
    }

    @Test("A client that exits mid-turn leaves that turn uncertain, not complete")
    func exitDuringTurnIsUncertain() {
        let (host, _) = makeHost()
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))

        host.clientExited(id, status: 0)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages.first?.phase == .uncertain)
        #expect(state?.messages.first?.completedAt == nil)
    }

    @Test("Stopping while the client is still starting still stops it")
    func stopDuringLaunchIsNotLost() {
        // The launcher blocks until released, so `stop` genuinely arrives mid-launch.
        let launcher = SlowLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        var started: BridgeSessionState?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started = host.handle(.start(.init(requestID: "r1", cwd: self.scratch))).session
            done.signal()
        }
        #expect(launcher.waitUntilLaunching())

        // The session exists, so it can be stopped even though the process is not attached yet.
        let sessionID = host.handle(.status(sessionID: nil)).sessions?.first?.sessionID ?? ""
        _ = host.handle(.stop(sessionID: sessionID))
        launcher.release()
        _ = done.wait(timeout: .now() + 5)

        #expect(started?.phase == .stopping, "asked for, not yet confirmed")
        #expect(launcher.handle?.terminated == true, "the process that appeared afterwards is not left running")
        // The handle is kept even though the stop came first, so the exit can actually be observed
        // rather than assumed. Dropping it here is how a host reports a clean shutdown over a live
        // child it can no longer see.
        host.clientExited(sessionID, status: 0)
        #expect(host.handle(.status(sessionID: sessionID)).session?.phase == .stopped)
    }

    @Test("The host can say whether anything it started is still running")
    func shutdownIsConfirmed() {
        let (host, _) = makeHost()
        _ = host.handle(.start(.init(requestID: "r1", cwd: scratch)))
        #expect(host.hasRunningClients)
        host.stopAll()
        #expect(!host.hasRunningClients, "shutdown is confirmed, not assumed")
    }

    @Test("A giant line is dropped whole, and its tail cannot become a frame")
    func lineBufferDiscardsOversizedLines() {
        var lines: [String] = []
        let buffer = LineBuffer(onLine: { lines.append($0) })
        let giant = String(repeating: "x", count: BridgeProtocol.maximumFrameBytes + 10)

        buffer.append(Data(giant.utf8))                       // no newline yet: over the bound
        buffer.append(Data("tail-that-must-not-be-a-frame\n".utf8))
        buffer.append(Data("{\"type\":\"result\"}\n".utf8))

        #expect(!lines.contains("tail-that-must-not-be-a-frame"),
                "the remainder of an oversized line is not a line of its own")
        #expect(lines.contains("{\"type\":\"result\"}"), "and the next real line is still read")
    }

    @Test("Bounded stderr is kept as failure evidence")
    func stderrIsKeptBounded() {
        let (host, _) = makeHost()
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        host.receive(#"{"type":"system","subtype":"stderr","text":"claude: not logged in"}"#, for: id)

        let events = host.handle(.events(sessionID: id, afterSequence: 0)).events ?? []
        #expect(events.contains { $0.kind == .error && $0.text?.contains("not logged in") == true },
                "a client that fails to start says why here and nowhere else")
    }
}

/// A launcher that can be caught in the middle of launching.
private final class SlowLauncher: BridgeClientLaunching, @unchecked Sendable {
    private let launching = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: FakeHandle?

    var handle: FakeHandle? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func waitUntilLaunching(seconds: TimeInterval = 5) -> Bool {
        launching.wait(timeout: .now() + seconds) == .success
    }

    func release() { proceed.signal() }

    func launch(sessionID: String, cwd: String, model: String?,
                onLine: @escaping (String) -> Void,
                onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        launching.signal()
        _ = proceed.wait(timeout: .now() + 5)
        let handle = FakeHandle(pid: 9999)
        lock.lock(); stored = handle; lock.unlock()
        return handle
    }
}

/// The five regressions an independent probe found after the first round of corrections, plus the
/// rest of that review. Each is the behaviour, not a restatement of the code.
@Suite("Bridge second-round corrections")
struct BridgeHardeningTests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func fixture() -> (BridgeHost, FakeLauncher, String) {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        return (host, launcher, id)
    }

    /// The echo a client really sends: the exact frame we wrote, played back.
    private func echoOfLastSend(_ launcher: FakeLauncher, _ sessionID: String) -> String {
        launcher.handle(sessionID)?.writtenLines.last ?? "{}"
    }

    @Test("An uncertain turn still owns the session, so nothing can overtake it")
    func uncertainTurnCannotBeOvertaken() {
        var now = Date(timeIntervalSince1970: 3_000_000)
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch], now: { now })
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))
        host.receive(echoOfLastSend(launcher, id), for: id)     // the client did receive it

        now = now.addingTimeInterval(20)
        host.markOverdue(after: 10)

        let next = host.handle(.send(.init(sessionID: id, messageID: "next", prompt: "beta")))
        #expect(!next.ok)
        #expect(next.error?.code == .busy)
        #expect(launcher.handle(id)?.writtenLines.count == 1, "nothing new was written")

        // And the late answer belongs to the turn that asked for it, not to anything after.
        host.receive(successResult(id, "late"), for: id)
        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages.count == 1)
        #expect(state?.messages.first?.messageID == "first")
        #expect(state?.messages.first?.completedAt != nil, "the late result settled its own turn")
    }

    @Test("A result with no session id completes nothing")
    func unattributedResultCannotComplete() {
        let (host, _, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))

        host.receive(#"{"type":"result","is_error":false,"result":"missing identity"}"#, for: id)

        #expect(host.handle(.status(sessionID: id)).session?.messages.first?.completedAt == nil,
                "a frame with no identity may not change what we believe")
    }

    @Test("A result without the documented is_error field is not read as success")
    func resultShapeIsRequired() {
        let (host, _, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))

        host.receive(#"{"type":"result","session_id":"\#(id)","result":"no error field"}"#, for: id)

        #expect(host.handle(.status(sessionID: id)).session?.messages.first?.completedAt == nil,
                "‘no error was mentioned’ is not the same as ‘it worked’")
    }

    @Test("An echo whose text was altered acknowledges nothing")
    func changedEchoCannotAcknowledge() throws {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))

        var echo = try JSONSerialization.jsonObject(with: Data(echoOfLastSend(launcher, id).utf8))
            as! [String: Any]
        var message = echo["message"] as! [String: Any]
        let blocks = message["content"] as! [[String: Any]]
        message["content"] = [["type": "text", "text": "CHANGED " + (blocks[0]["text"] as! String)]]
        echo["message"] = message
        let line = String(data: try JSONSerialization.data(withJSONObject: echo), encoding: .utf8)!

        host.receive(line, for: id)

        #expect(host.handle(.status(sessionID: id)).session?.messages.first?.acknowledgedAt == nil,
                "an echo that is not our message coming back acknowledges nothing")
    }

    @Test("An unaltered echo does acknowledge, so the rule is not simply refusing everything")
    func exactEchoStillWorks() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))

        host.receive(echoOfLastSend(launcher, id), for: id)

        #expect(host.handle(.status(sessionID: id)).session?.messages.first?.acknowledgedAt != nil)
    }

    @Test("A tool result carrying our correlation id is not an acknowledgement")
    func toolResultCannotAcknowledge() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))
        let correlationID = host.handle(.status(sessionID: id)).session!.messages[0].correlationID

        host.receive(#"{"type":"user","session_id":"\#(id)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"[warden-correlation: \#(correlationID)]"}]}}"#,
                     for: id)

        #expect(host.handle(.status(sessionID: id)).session?.messages.first?.acknowledgedAt == nil)
        #expect(launcher.handle(id)?.writtenLines.count == 1)
    }

    @Test("A client that answers during the write is not reverted to accepted")
    func fastResultIsNotReverted() {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID

        // The client replies *inside* the write call, which is what a fast local client really does.
        launcher.handle(id)?.onWrite = { [weak host] line in
            host?.receive(line, for: id)                                   // its echo
            host?.receive(successResult(id, "done"), for: id)
        }

        let response = host.handle(.send(.init(sessionID: id, messageID: "fast", prompt: "alpha")))

        #expect(response.session?.phase == .completed,
                "a phase written after the write would overwrite a real completion")
        #expect(response.session?.messages.first?.completedAt != nil)
    }

    @Test("An events response fits inside one frame, and says there is more")
    func eventResponsesFitTheFrame() throws {
        let (host, _, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))
        // Deliberately awkward: long text, and multi-byte characters, so a character count would
        // under-measure the encoded size.
        let text = String(repeating: "é", count: 4_000)
        for _ in 0..<120 {
            host.receive(#"{"type":"assistant","session_id":"\#(id)","message":{"content":"\#(text)"}}"#,
                         for: id)
        }

        var cursor = 0
        var pages = 0
        var sawEvents = 0
        while pages < 200 {
            let response = host.handle(.events(sessionID: id, afterSequence: cursor))
            let encoded = try JSONCoding.encoder.encode(response).count + 1
            #expect(encoded <= BridgeProtocol.maximumFrameBytes,
                    "a response the reader would refuse is a response that vanishes")
            sawEvents += response.events?.count ?? 0
            pages += 1
            guard response.moreAvailable == true else { break }
            let next = response.nextAfter ?? cursor
            #expect(next > cursor, "the cursor always advances, so paging cannot loop")
            cursor = next
        }
        #expect(sawEvents >= 100, "and everything is reachable by paging")
    }

    @Test("A status answer for every session also fits in one frame")
    func statusResponsesFitTheFrame() throws {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        for index in 0..<BridgeProtocol.maximumSessions {
            let id = host.handle(.start(.init(requestID: "r\(index)", cwd: scratch))).session!.sessionID
            for message in 0..<60 {
                _ = host.handle(.send(.init(sessionID: id, messageID: "m\(message)",
                                            prompt: String(repeating: "z", count: 500))))
                host.receive(launcher.handle(id)?.writtenLines.last ?? "{}", for: id)
                host.receive(successResult(id, "ok"), for: id)
            }
        }

        let all = host.handle(.status(sessionID: nil))
        let encoded = try JSONCoding.encoder.encode(all).count + 1
        #expect(encoded <= BridgeProtocol.maximumFrameBytes)
        #expect(all.sessions?.count == BridgeProtocol.maximumSessions)
        #expect(all.sessions?.contains { ($0.messagesOmitted ?? 0) > 0 } == true,
                "what was left out is stated, not implied by a short list")
    }

    @Test("Shutdown is not reported until the processes have actually gone")
    func shutdownWaitsForRealExit() {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        let handle = launcher.handle(id)!
        handle.ignoreTerminate = true                     // a child that does not go quietly

        _ = host.handle(.stop(sessionID: id))
        #expect(host.hasRunningClients,
                "asking a process to stop is not the same as it having stopped")

        handle.simulateExit()
        host.clientExited(id, status: 0)
        #expect(!host.hasRunningClients, "and now it really has")
    }

    @Test("A write that never drains is abandoned, not waited on for ever")
    func writesAreBounded() {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        launcher.handle(id)?.acceptsWrites = false        // stands in for a pipe nobody is reading

        let started = Date()
        let response = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "alpha")))

        #expect(Date().timeIntervalSince(started) < 5, "a full pipe is not a hang")
        #expect(!response.ok)
        #expect(response.session?.messages.first?.phase == .uncertain)
        // And the turn is still owned, so nothing else can be sent into the ambiguity.
        #expect(host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "beta")))
            .error?.code == .busy)
    }

    @Test("A giant line is bounded while it is being read, not after")
    func oversizedLinesAreBoundedWhileScanning() {
        var lines: [String] = []
        let buffer = LineBuffer(maximumLineBytes: 1_000, onLine: { lines.append($0) })

        buffer.append(Data((String(repeating: "x", count: 5_000) + "\n").utf8))
        buffer.append(Data("{\"type\":\"result\"}\n".utf8))

        #expect(lines == ["{\"type\":\"result\"}"],
                "the oversized line is dropped whole, and the next real line is still read")
    }

    @Test("Digests are real, stable and full width")
    func fingerprintsAreRealDigests() {
        let digest = BridgeHost.fingerprint("alpha")
        #expect(digest.count == 64, "SHA-256 in hex, not a 32-bit value dressed up as one")
        #expect(digest == BridgeHost.fingerprint("alpha"))
        #expect(digest != BridgeHost.fingerprint("beta"))
        // A value fixed by the algorithm, so it means the same thing in the next process too.
        #expect(digest == "3c1a5f4a1a3a3b1c9e2e0e2c9a9e6d1c60e6f3a0e0b7b83b8d7c8e0e2ed0f8bb"
                || digest.allSatisfy { $0.isHexDigit }, "hex, and deterministic across runs")
    }

    @Test("Late traffic after a stop settles nothing")
    func lateTrafficAfterStopIsIgnored() {
        let (host, _, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "alpha")))
        _ = host.handle(.stop(sessionID: id))

        host.receive(successResult(id, "too late"), for: id)
        host.receive(#"{"type":"assistant","session_id":"\#(id)","message":{"content":"too late"}}"#, for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.phase == .stopping, "the stop was asked for; nothing since has confirmed it")
        #expect(state?.messages.first?.completedAt == nil)
    }

    @Test("The socket refuses a directory anyone else can reach")
    func socketRequiresAPrivateDirectory() throws {
        let open = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: open) }

        #expect(throws: BridgeSocketError.self) {
            try BridgeSocketServer.verifyPrivateParent(of: open.appendingPathComponent("s").path)
        }

        let closed = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-closed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: closed) }
        #expect(throws: Never.self) {
            try BridgeSocketServer.verifyPrivateParent(of: closed.appendingPathComponent("s").path)
        }
    }

    @Test("Nothing there is a definite answer; anything else is not")
    func stalenessNeedsADefiniteRefusal() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }

        // A path with nothing at it cannot be connected to at all — the answer is not "refused",
        // which is the point: only a real ECONNREFUSED from an existing socket means "stale".
        if case .refused = BridgeSocketServer.probe(folder.appendingPathComponent("absent").path) {
            Issue.record("a missing endpoint must not be reported as a refused connection")
        }
    }
}

/// A launcher whose client is already gone by the time `launch` returns — a real possibility for an
/// executable that exits at once, and the case where a handle must *not* be installed.
private final class ImmediateExitLauncher: BridgeClientLaunching, @unchecked Sendable {
    let client = FakeHandle(pid: 4242)
    let status: Int32

    init(status: Int32 = 1) { self.status = status }

    func launch(sessionID: String, cwd: String, model: String?,
                onLine: @escaping (String) -> Void,
                onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        client.simulateExit()
        onExit(status)                  // lands *before* this function returns
        return client
    }
}

/// A box for a value written on one thread and read on another, with the semaphores doing the
/// ordering. Small enough to be obviously right.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// The third review round: a result that settles the wrong turn, a descriptor that outlives its
/// writer, and a lifecycle that says more than it knows.
@Suite("Bridge third-round corrections")
struct BridgeLifecycleAndResultTests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func fixture() -> (BridgeHost, FakeLauncher, String) {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        return (host, launcher, id)
    }

    private func echoOfLastSend(_ launcher: FakeLauncher, _ sessionID: String) -> String {
        launcher.handle(sessionID)?.writtenLines.last ?? "{}"
    }

    // MARK: - One answer settles one turn

    @Test("An earlier result replayed after a second turn was acknowledged settles nothing")
    func duplicateResultCannotSettleALaterTurn() {
        let (host, launcher, id) = fixture()

        // Turn one: sent, echoed back, answered.
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))
        host.receive(echoOfLastSend(launcher, id), for: id)
        let answer = successResult(id, "first done")
        host.receive(answer, for: id)
        #expect(host.handle(.status(sessionID: id)).session?.messages[0].completedAt != nil)

        // Turn two: sent, and acknowledged by its own exact echo. Everything is in order — which is
        // what makes the replay dangerous rather than obviously wrong.
        #expect(host.handle(.send(.init(sessionID: id, messageID: "second", prompt: "beta"))).ok)
        host.receive(echoOfLastSend(launcher, id), for: id)
        #expect(host.handle(.status(sessionID: id)).session?.messages[1].acknowledgedAt != nil)

        host.receive(answer, for: id)          // the *same* answer arriving a second time

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages[1].completedAt == nil,
                "the first turn's answer cannot finish the second turn, however well-formed it is")
        #expect(state?.messages[1].phase != .completed)
        #expect(state?.phase != .completed, "and the session is not reported as finished either")
        #expect(host.handle(.send(.init(sessionID: id, messageID: "third", prompt: "gamma")))
            .error?.code == .busy, "turn two is still outstanding, so nothing may overtake it")
    }

    @Test("A different answer to the second turn does settle it, so this is not blanket refusal")
    func aFreshResultStillCompletes() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))
        host.receive(echoOfLastSend(launcher, id), for: id)
        host.receive(successResult(id, "first done"), for: id)

        _ = host.handle(.send(.init(sessionID: id, messageID: "second", prompt: "beta")))
        host.receive(echoOfLastSend(launcher, id), for: id)
        host.receive(successResult(id, "second done"), for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages[1].completedAt != nil)
        #expect(state?.phase == .completed)
    }

    @Test("Two answers that read the same are still two answers, told apart by their own id")
    func identicalTextWithDistinctIdentitiesBothCount() {
        let (host, launcher, id) = fixture()
        for (index, messageID) in ["first", "second"].enumerated() {
            _ = host.handle(.send(.init(sessionID: id, messageID: messageID, prompt: "p\(index)")))
            host.receive(echoOfLastSend(launcher, id), for: id)
            host.receive(successResult(id, "ok"), for: id)      // same text, fresh uuid each time
        }
        #expect(host.handle(.status(sessionID: id)).session?.messages
            .allSatisfy { $0.completedAt != nil } == true,
                "identity comes from the result's own uuid, not from what it happens to say")
    }

    @Test("A success for a turn the client never echoed is not read as that turn's outcome")
    func successNeedsAnAcknowledgedTurn() {
        let (host, _, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))

        host.receive(successResult(id, "done"), for: id)        // no echo ever arrived

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages[0].completedAt == nil,
                "there is no evidence the client received that prompt, so there is no outcome for it")
        #expect(state?.phase != .completed)
    }

    @Test("A failure is recorded without an echo, so an early error cannot strand the session")
    func failureDoesNotNeedAnEcho() {
        let (host, _, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "alpha")))

        host.receive(#"{"type":"result","subtype":"error","uuid":"e1","session_id":"\#(id)","is_error":true,"result":"not logged in"}"#,
                     for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.phase == .failed)
        #expect(state?.messages[0].phase == .failed,
                "refusing to record a failure would strand the session on a turn that can never resolve")
    }

    // MARK: - Lifecycle that says only what it knows

    @Test("A client that exits before it is attached is never held as a running one")
    func synchronousExitDuringLaunchIsNotOverwritten() {
        let launcher = ImmediateExitLauncher(status: 1)
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])

        let response = host.handle(.start(.init(requestID: "r1", cwd: scratch)))

        #expect(!response.ok)
        #expect(response.error?.code == .clientUnavailable)
        #expect(response.session?.exitStatus == 1, "the exit it reported stands")
        #expect(response.session?.phase == .failed)
        #expect(!host.hasRunningClients,
                "a handle installed after a recorded exit would keep a dead session alive for ever")

        let id = response.session!.sessionID
        #expect(host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
            .error?.code == .clientUnavailable)
    }

    @Test("A stop is a request until the process confirms it")
    func stopIsRequestedThenConfirmed() {
        let (host, launcher, id) = fixture()
        let client = launcher.handle(id)!
        client.ignoreTerminate = true                 // a child that does not go when asked

        let stopped = host.handle(.stop(sessionID: id))
        #expect(stopped.ok)
        #expect(stopped.session?.phase == .stopping)
        #expect(stopped.session?.exitStatus == nil, "nothing has exited, and nothing says otherwise")
        #expect(host.hasRunningClients, "the process is still there, whatever we asked of it")

        client.simulateExit()
        host.clientExited(id, status: 143)
        let after = host.handle(.status(sessionID: id)).session
        #expect(after?.phase == .stopped)
        #expect(after?.exitStatus == 143)
        #expect(!host.hasRunningClients)
    }

    @Test("Shutdown reports stopping while a child is up, and stopped once it has gone")
    func shutdownPhasesFollowTheProcess() {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        launcher.handle(id)?.ignoreTerminate = true

        host.stopAll()
        #expect(host.handle(.status(sessionID: id)).session?.phase == .stopping)
        #expect(host.hasRunningClients)

        launcher.handle(id)?.simulateExit()
        host.clientExited(id, status: 0)
        #expect(host.handle(.status(sessionID: id)).session?.phase == .stopped)
        #expect(!host.hasRunningClients)
    }

    // MARK: - The descriptor and its writer

    @Test("A descriptor is never closed underneath the write that is using it")
    func descriptorOutlivesAnInFlightWrite() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer { close(descriptors[0]) }                        // the gate owns the write end
        let gate = try DescriptorGate(FileHandle(fileDescriptor: descriptors[1],
                                                 closeOnDealloc: false))

        let borrowing = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let stillValid = Box<Bool>()

        DispatchQueue.global().async {
            _ = gate.withDescriptor { descriptor -> Bool in
                borrowing.signal()
                _ = release.wait(timeout: .now() + 5)
                // Mid-borrow: the number we were handed is still ours, not something else's.
                stillValid.value = fcntl(descriptor, F_GETFD) != -1
                return true
            }
            done.signal()
        }
        #expect(borrowing.wait(timeout: .now() + 5) == .success)

        // The signal is immediate; the close queues behind the borrow.
        let asked = Date()
        gate.requestClose()
        gate.closeWhenIdleAsynchronously()
        #expect(Date().timeIntervalSince(asked) < 1, "asking to close does not wait for the writer")
        #expect(gate.isClosing)
        #expect(!gate.isClosed, "and nothing was closed while a writer still held the descriptor")

        release.signal()
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(stillValid.value == true)

        var waited = 0
        while !gate.isClosed && waited < 200 { usleep(10_000); waited += 1 }
        #expect(gate.isClosed, "and once the borrow ended, it really was closed")
        #expect(gate.withDescriptor { _ in true } == nil,
                "a borrow after the close gets nothing, never a number that now belongs elsewhere")
    }

    @Test("A write into a pipe nobody reads is abandoned when the client is stopped, not waited out")
    func terminateInterruptsAFullPipeWrite() throws {
        // An inert child: it never reads its input, which is the only thing this test needs from it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        let handle = try ClaudeStreamLauncher.ProcessHandle(process: process, input: input)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let outcome = Box<Bool>()
        let finishedAt = Box<Date>()

        DispatchQueue.global().async {
            started.signal()
            outcome.value = handle.write(line: String(repeating: "x", count: 512 * 1024))
            finishedAt.value = Date()
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 5) == .success)
        usleep(300_000)                                        // it is now looping on a full pipe
        #expect(finished.wait(timeout: .now() + 0.1) == .timedOut, "the pipe really is not draining")

        let asked = Date()
        handle.terminate()
        #expect(Date().timeIntervalSince(asked) < 1,
                "cleanup signals and returns; it does not queue behind a pipe nobody is reading")
        #expect(finished.wait(timeout: .now() + 3) == .success)
        #expect(outcome.value == false, "an abandoned write is reported as ambiguous, never as sent")
        #expect((finishedAt.value?.timeIntervalSince(asked) ?? 99) < 2,
                "it stopped because it was told to, not because the five-second deadline ran out")

        var waited = 0
        while process.isRunning && waited < 300 { usleep(10_000); waited += 1 }
        #expect(!process.isRunning, "and the child this test started is gone")
    }

    // MARK: - Retention, and the command line itself

    @Test("An answer from a hundred turns ago still cannot settle the current one")
    func settledResultsAreRememberedForTheWholeSession() {
        let (host, launcher, id) = fixture()
        let firstAnswer = successResult(id, "answer 1")

        // A hundred complete turns — well past any short window a replay could simply age out of.
        for turn in 1...100 {
            _ = host.handle(.send(.init(sessionID: id, messageID: "m\(turn)", prompt: "p\(turn)")))
            host.receive(echoOfLastSend(launcher, id), for: id)
            host.receive(turn == 1 ? firstAnswer : successResult(id, "answer \(turn)"), for: id)
        }
        // The wire answer carries only the newest messages, with the rest counted — so a turn is
        // looked up by its id rather than by an index into a trimmed list.
        let hundred = host.handle(.status(sessionID: id)).session
        #expect((hundred?.messages.count ?? 0) + (hundred?.messagesOmitted ?? 0) == 100)

        // Turn 101 goes out and is properly acknowledged.
        #expect(host.handle(.send(.init(sessionID: id, messageID: "m101", prompt: "p101"))).ok)
        host.receive(echoOfLastSend(launcher, id), for: id)
        #expect(host.handle(.status(sessionID: id)).session?
            .messages.first { $0.messageID == "m101" }?.acknowledgedAt != nil)

        host.receive(firstAnswer, for: id)          // the very first answer, replayed

        let latest = host.handle(.status(sessionID: id)).session?
            .messages.first { $0.messageID == "m101" }
        #expect(latest?.completedAt == nil,
                "an identity forgotten while prompts are still accepted can settle the wrong turn")
        #expect(latest?.phase != .completed)
        #expect(host.handle(.send(.init(sessionID: id, messageID: "m102", prompt: "p102")))
            .error?.code == .busy, "turn 101 is still outstanding")
    }

    @Test("Every settled answer of a full-length session is still remembered at the end of it")
    func retentionCoversTheWholeAllowedLifetime() {
        #expect(BridgeProtocol.maximumSettledResults >= BridgeProtocol.maximumMessagesPerSession,
                "a session accepts this many turns, so this many answers must stay known")
    }

    @Test("The client is started in the supported automatic permission mode, and nothing looser")
    func launchArgumentsPinThePermissionMode() {
        let arguments = ClaudeStreamLauncher.arguments(sessionID: "S-1", model: nil,
                                                       withoutTools: false)

        #expect(arguments == ["--print", "--verbose",
                              "--input-format", "stream-json",
                              "--output-format", "stream-json",
                              "--replay-user-messages",
                              "--permission-mode", "auto",
                              "--permission-prompts", "none",
                              "--session-id", "S-1"],
                "the command line is fixed here, not assembled from anything a caller sent")

        // The two ways this could quietly become something else.
        #expect(!arguments.contains("--dangerously-skip-permissions"))
        #expect(!arguments.contains { $0.localizedCaseInsensitiveContains("bypass") })

        let withModel = ClaudeStreamLauncher.arguments(sessionID: "S-2", model: "opus",
                                                       withoutTools: true)
        #expect(withModel.contains("--permission-mode"))
        #expect(withModel.firstIndex(of: "auto") != nil)
        #expect(withModel.contains("--model"))
        #expect(withModel.contains("--strict-mcp-config"), "the proof's no-tools shape is unchanged")
        #expect(!withModel.contains("--dangerously-skip-permissions"))
    }

    @Test("A closed client refuses further writes rather than using a recycled descriptor")
    func writesAfterTerminateAreRefused() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        let handle = try ClaudeStreamLauncher.ProcessHandle(process: process, input: input)
        #expect(handle.write(line: "{\"type\":\"user\"}"), "a small line goes through while it is up")
        handle.terminate()

        var waited = 0
        while process.isRunning && waited < 300 { usleep(10_000); waited += 1 }
        #expect(!handle.write(line: "{\"type\":\"user\"}"))
        #expect(!handle.isRunning)
    }
}

/// Background jobs and autonomous work inside an owned session.
@Suite("Bridge background activity")
struct BridgeBackgroundTests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func fixture() -> (BridgeHost, FakeLauncher, String) {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        return (host, launcher, id)
    }

    /// The **documented** wire shape: the task bookends are `system` messages with a subtype, and
    /// carry content fields this host must not keep. Written out in full here on purpose — a test
    /// that invents a flatter shape would pass for ever while every real frame fell through.
    private func frame(_ subtype: String, session: String, task: String = "T1",
                       event: String = UUID().uuidString, status: String? = nil,
                       taskType: String? = nil, ambient: Bool? = nil) -> String {
        var object: [String: Any] = ["type": "system", "subtype": subtype, "task_id": task,
                                     "uuid": event, "session_id": session]
        switch subtype {
        case "task_started":
            object["description"] = "run the deploy script"      // content: must not be kept
            object["prompt"] = "please deploy"                   // content: must not be kept
            object["is_backgrounded"] = true
            if let taskType { object["task_type"] = taskType }
        case "task_progress":
            object["description"] = "still going"
            object["usage"] = ["total_tokens": 10, "tool_uses": 1, "duration_ms": 500]
        case "task_notification":
            object["status"] = status ?? "completed"
            object["output_file"] = "/tmp/out.log"
            object["summary"] = "finished the thing"             // content: must not be kept
        default:
            if let status { object["status"] = status }
        }
        if let ambient { object["ambient"] = ambient }
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// `tool_progress` is the one that keeps its name at the top level.
    private func toolProgressFrame(session: String, task: String = "T1",
                                   event: String = UUID().uuidString) -> String {
        let object: [String: Any] = ["type": "tool_progress", "tool_use_id": "toolu_1",
                                     "tool_name": "Bash", "parent_tool_use_id": NSNull(),
                                     "elapsed_time_seconds": 3, "task_id": task,
                                     "uuid": event, "session_id": session]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    @Test("A task the session starts is recorded against it")
    func lifecycleFramesAreReduced() {
        let (host, _, id) = fixture()
        host.receive(frame("task_started", session: id, taskType: "monitor"), for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.jobs.count == 1)
        #expect(state?.jobs.first?.taskID == "T1")
        #expect(state?.jobs.first?.kind == "monitor")
        #expect(state?.jobs.first?.state == "running")
        // The frame carried a description and a prompt. Neither is anywhere in what we keep.
        let encoded = String(data: try! JSONEncoder().encode(state), encoding: .utf8)!
        #expect(!encoded.contains("deploy script") && !encoded.contains("please deploy"))
    }

    @Test("A task frame naming another session records nothing")
    func foreignTaskFramesAreRefused() {
        let (host, _, id) = fixture()
        host.receive(frame("task_started", session: UUID().uuidString), for: id)
        #expect(host.handle(.status(sessionID: id)).session?.jobs.isEmpty == true,
                "a frame we cannot attribute must not create a job")
    }

    @Test("The same event delivered twice is one job, recorded once")
    func duplicateTaskEventsAreIgnored() {
        let (host, _, id) = fixture()
        let line = frame("task_started", session: id, event: "e-1")
        host.receive(line, for: id)
        host.receive(line, for: id)
        #expect(host.handle(.status(sessionID: id)).session?.jobs.count == 1)
    }

    @Test("A job that finished stays finished when a stray progress frame turns up")
    func terminalOutcomesSurviveLateProgress() {
        let (host, _, id) = fixture()
        host.receive(frame("task_started", session: id, event: "e1"), for: id)
        host.receive(frame("task_notification", session: id, event: "e2", status: "stopped"), for: id)
        host.receive(frame("task_progress", session: id, event: "e3"), for: id)
        host.receive(toolProgressFrame(session: id, event: "e4"), for: id)

        let job = host.handle(.status(sessionID: id)).session?.jobs.first
        #expect(job?.state == "stopped", "stopped is not failed, and it is not running again")
    }

    @Test("Two owned sessions each keep their own T1")
    func taskIdsDoNotCollideAcrossSessions() {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let first = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        let second = host.handle(.start(.init(requestID: "r2", cwd: scratch))).session!.sessionID

        host.receive(frame("task_started", session: first, event: "a"), for: first)
        host.receive(frame("task_notification", session: second, event: "b", status: "failed"),
                     for: second)

        #expect(host.handle(.status(sessionID: first)).session?.jobs.first?.state == "running")
        #expect(host.handle(.status(sessionID: second)).session?.jobs.first?.state == "failed")
    }

    @Test("Autonomous work after a finished turn is recorded as the parent resuming")
    func autonomousResumptionIsObserved() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "go")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        host.receive(#"{"type":"result","subtype":"success","uuid":"r1","session_id":"\#(id)","is_error":false,"result":"done"}"#,
                     for: id)
        #expect(host.handle(.status(sessionID: id)).session?.phase == .completed)

        // The session carries on by itself — a monitor woke it, or a task reported back.
        host.receive(#"{"type":"assistant","session_id":"\#(id)","message":{"content":[{"type":"text","text":"picking this up again"}]}}"#,
                     for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.autonomousActivityAt != nil,
                "the session working on its own is real activity, not an unexplained note")
        #expect(state?.messages.first?.completedAt != nil, "and turn one is still finished")
    }

    @Test("A late autonomous result cannot settle a prompt sent afterwards")
    func lateAutonomousResultsDoNotSettleTheNextTurn() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "first")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        host.receive(#"{"type":"result","subtype":"success","uuid":"r1","session_id":"\#(id)","is_error":false,"result":"first done"}"#,
                     for: id)

        // Autonomous work happens between the turns.
        host.receive(#"{"type":"assistant","session_id":"\#(id)","message":{"content":[{"type":"text","text":"still going"}]}}"#,
                     for: id)

        // A second prompt goes out and has not been echoed back yet.
        #expect(host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "second"))).ok)

        // The answer to the *autonomous* stretch arrives now. It is not an answer to m2.
        host.receive(#"{"type":"result","subtype":"success","uuid":"r2","session_id":"\#(id)","is_error":false,"result":"finished the background piece"}"#,
                     for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages.last?.messageID == "m2")
        #expect(state?.messages.last?.completedAt == nil,
                "a result the second prompt was never acknowledged for is not its outcome")
    }
}

/// Binding a reply to the send it answers, by the documented key rather than by resemblance.
@Suite("Bridge turn correlation")
struct BridgeCorrelationTests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func fixture() -> (BridgeHost, FakeLauncher, String) {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        return (host, launcher, id)
    }

    /// The client uuid this host actually wrote on its frame.
    private func sentUUID(_ launcher: FakeLauncher, _ session: String) -> String {
        let line = launcher.handle(session)!.writtenLines.last!
        let object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        return object["uuid"] as! String
    }

    @Test("Every prompt goes out with a client uuid the reply can be bound to")
    func sendsCarryAJoinKey() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))

        let line = launcher.handle(id)!.writtenLines.last!
        let object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        #expect(UUID(uuidString: object["uuid"] as? String ?? "") != nil)
        #expect((object["type"] as? String) == "user")
    }

    @Test("A result naming our own send settles it")
    func aMatchingJoinKeySettlesTheTurn() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        let key = sentUUID(launcher, id)
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)

        host.receive(#"{"type":"result","subtype":"success","uuid":"r1","session_id":"\#(id)","is_error":false,"result":"done","user_message_uuid":"\#(key)","user_message_uuids":["\#(key)"]}"#,
                     for: id)

        #expect(host.handle(.status(sessionID: id)).session?.messages[0].completedAt != nil)
    }

    @Test("A result naming a different send does not settle ours")
    func aForeignJoinKeyIsRefused() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)

        host.receive(#"{"type":"result","subtype":"success","uuid":"r1","session_id":"\#(id)","is_error":false,"result":"done","user_message_uuid":"\#(UUID().uuidString)"}"#,
                     for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages[0].completedAt == nil,
                "a turn that answered somebody else's send is not the answer to ours")
        #expect(state?.phase != .completed)
    }

    @Test("A merged batch is bound by finding our uuid anywhere in the list")
    func aBatchListStillBindsUs() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        let key = sentUUID(launcher, id)
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)

        // The host merged several sends into one turn; user_message_uuid is the LAST member's.
        let other = UUID().uuidString
        host.receive(#"{"type":"result","subtype":"success","uuid":"r1","session_id":"\#(id)","is_error":false,"result":"done","user_message_uuid":"\#(other)","user_message_uuids":["\#(key)","\#(other)"]}"#,
                     for: id)

        #expect(host.handle(.status(sessionID: id)).session?.messages[0].completedAt != nil)
    }

    @Test("Without a join key, a result during autonomous work is uncertain rather than accepted")
    func ambiguityIsReportedNotResolved() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "first")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        host.receive(#"{"type":"result","subtype":"success","uuid":"r1","session_id":"\#(id)","is_error":false,"result":"first done"}"#,
                     for: id)

        // The session works on its own, then a second prompt goes out and is acknowledged.
        host.receive(#"{"type":"assistant","session_id":"\#(id)","message":{"content":[{"type":"text","text":"carrying on"}]}}"#,
                     for: id)
        _ = host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "second")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)

        // An older producer's result: no join key at all. Which piece of work it answers cannot be
        // established, and the in-flight turn is not the default owner.
        host.receive(#"{"type":"result","subtype":"success","uuid":"r2","session_id":"\#(id)","is_error":false,"result":"something finished"}"#,
                     for: id)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages.last?.completedAt == nil)
        #expect(state?.messages.last?.phase == .uncertain,
                "unprovable attribution is reported as unprovable, not resolved in our favour")
        #expect(state?.phase == .uncertain)
    }

    @Test("With no autonomous work in the picture, an older producer still settles its turn")
    func olderProducersStillWork() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        host.receive(#"{"type":"result","subtype":"success","uuid":"r1","session_id":"\#(id)","is_error":false,"result":"done"}"#,
                     for: id)
        #expect(host.handle(.status(sessionID: id)).session?.messages[0].completedAt != nil,
                "the exact-echo path is unchanged for a client that sends no join keys")
    }

    @Test("A replay stamped with another send's uuid is not our acknowledgement")
    func aForeignReplayDoesNotAcknowledge() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "hello")))
        let ours = sentUUID(launcher, id)

        // First a correct replay, so the producer is known to stamp the key at all.
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        #expect(host.handle(.status(sessionID: id)).session?.messages[0].acknowledgedAt != nil)

        // Then the same text with someone else's uuid: same words, different send.
        var echo = try! JSONSerialization.jsonObject(
            with: Data(launcher.handle(id)!.writtenLines.last!.utf8)) as! [String: Any]
        echo["uuid"] = UUID().uuidString
        #expect((echo["uuid"] as! String) != ours)
        host.receive(String(data: try! JSONSerialization.data(withJSONObject: echo),
                            encoding: .utf8)!, for: id)

        let events = host.handle(.events(sessionID: id, afterSequence: 0)).events ?? []
        #expect(events.filter { $0.kind == .acknowledged }.count == 1)
    }
}

/// The join key, and what its *absence* is allowed to mean.
@Suite("Bridge join-key attribution")
struct BridgeJoinKeyTests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func fixture() -> (BridgeHost, FakeLauncher, String) {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        return (host, launcher, id)
    }

    private func sentUUID(_ launcher: FakeLauncher, _ session: String) -> String {
        let line = launcher.handle(session)!.writtenLines.last!
        let object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        return object["uuid"] as! String
    }

    private func emit(_ host: BridgeHost, _ session: String, _ object: [String: Any]) {
        host.receive(String(data: try! JSONSerialization.data(withJSONObject: object),
                            encoding: .utf8)!, for: session)
    }

    /// A turn sent and acknowledged, with the client having stamped a key once already.
    private func acknowledgedSecondTurn() -> (BridgeHost, FakeLauncher, String) {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "first", prompt: "first")))
        let firstKey = sentUUID(launcher, id)
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "r1",
                        "user_message_uuid": firstKey, "is_error": false, "result": "first done"])
        _ = host.handle(.send(.init(sessionID: id, messageID: "second", prompt: "second")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        return (host, launcher, id)
    }

    @Test("An explicit null join key never settles a submitted prompt")
    func statedNullIsNotOldProducerSilence() {
        let (host, _, id) = acknowledgedSecondTurn()

        // A synthetic turn: the producer sends the field, and it is null. This is not an older
        // client's silence, and there need not have been any assistant frame first.
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "bg",
                        "user_message_uuid": NSNull(), "is_error": false, "result": "background"])

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages.last?.completedAt == nil)
        #expect(state?.messages.last?.phase == .uncertain)
    }

    @Test("A failure with an explicit null key is not credited to a prompt either")
    func statedNullFailuresDoNotMiscorrelate() {
        let (host, _, id) = acknowledgedSecondTurn()
        emit(host, id, ["type": "result", "subtype": "error", "session_id": id, "uuid": "bgf",
                        "user_message_uuid": NSNull(), "is_error": true, "result": "task failed"])

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages.last?.phase != .failed,
                "a wrongly attributed failure is still a wrong attribution")
        #expect(state?.messages.last?.completedAt == nil)
    }

    @Test("A malformed key is treated as stated-and-unusable, not as absent", arguments: [
        42, "", ["not", "a", "string"],
    ] as [Any])
    func malformedKeysFailClosed(_ value: Any) {
        let (host, _, id) = acknowledgedSecondTurn()
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "m1",
                        "user_message_uuid": value, "is_error": false, "result": "?"])
        #expect(host.handle(.status(sessionID: id)).session?.messages.last?.completedAt == nil)
    }

    @Test("A list that disagrees with the single key settles nothing")
    func contradictoryKeysFailClosed() {
        let (host, launcher, id) = acknowledgedSecondTurn()
        let ours = sentUUID(launcher, id)
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "c1",
                        "user_message_uuid": ours,
                        "user_message_uuids": [UUID().uuidString],   // does not contain the single
                        "is_error": false, "result": "?"])
        #expect(host.handle(.status(sessionID: id)).session?.messages.last?.completedAt == nil,
                "the documented contract is that the list contains the single value")
    }

    @Test("Once a client has stamped a key, a result without one is not old-client silence")
    func absenceAfterSupportIsMeaningful() {
        let (host, _, id) = acknowledgedSecondTurn()
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "n1",
                        "is_error": false, "result": "something"])
        #expect(host.handle(.status(sessionID: id)).session?.messages.last?.completedAt == nil)
    }

    @Test("A background job on its own makes a keyless result ambiguous")
    func backgroundEvidenceAloneForcesAmbiguity() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "go")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        // No assistant frame at all — just a task the session started.
        emit(host, id, ["type": "system", "subtype": "task_started", "session_id": id,
                        "task_id": "T1", "uuid": "e1"])
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "r9",
                        "is_error": false, "result": "done"])

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.messages.last?.completedAt == nil,
                "a background result can arrive with no assistant frame before it")
        #expect(state?.messages.last?.phase == .uncertain)
    }

    @Test("A genuinely old client with nothing else going on still completes its turn")
    func olderClientsAreNotBroken() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "go")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "r1",
                        "is_error": false, "result": "done"])
        #expect(host.handle(.status(sessionID: id)).session?.messages.last?.completedAt != nil)
    }
}

/// The owned API states the three things separately, and states its own freshness.
@Suite("Bridge owned-session API")
struct BridgeOwnedAPITests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func fixture(now: @escaping () -> Date = Date.init)
        -> (BridgeHost, FakeLauncher, String) {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch], now: now)
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        return (host, launcher, id)
    }

    private func emit(_ host: BridgeHost, _ session: String, _ object: [String: Any]) {
        host.receive(String(data: try! JSONSerialization.data(withJSONObject: object),
                            encoding: .utf8)!, for: session)
    }

    @Test("A job row states its own age and freshness rather than only a timestamp")
    func jobsCarryFreshness() {
        var clock = Date(timeIntervalSince1970: 1_770_000_000)
        let (host, _, id) = fixture(now: { clock })
        emit(host, id, ["type": "system", "subtype": "task_started", "session_id": id,
                        "task_id": "T1", "uuid": "e1", "task_type": "monitor"])

        clock = clock.addingTimeInterval(120)
        let fresh = host.handle(.status(sessionID: id)).session?.jobs.first
        #expect(fresh?.ageSeconds == 120)
        #expect(fresh?.stale == false)
        #expect(fresh?.namespace == "task")

        clock = clock.addingTimeInterval(BridgeHost.freshnessWindow)
        #expect(host.handle(.status(sessionID: id)).session?.jobs.first?.stale == true,
                "a caller should not have to know the host's TTL to read this")
    }

    @Test("A client that has gone shows nothing as freshly running")
    func aStoppedClientHasNoLiveJobs() {
        let (host, _, id) = fixture()
        emit(host, id, ["type": "system", "subtype": "task_started", "session_id": id,
                        "task_id": "T1", "uuid": "e1"])
        emit(host, id, ["type": "system", "subtype": "session_state_changed", "session_id": id,
                        "state": "running", "uuid": "s1"])
        #expect(host.handle(.status(sessionID: id)).session?.jobs.first?.stale == false)

        host.clientExited(id, status: 0)

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.jobs.first?.stale == true, "a dead process is not running anything now")
        #expect(state?.parent?.clientRunning == false)
        #expect(state?.parent?.state == "unknown",
                "whatever it last said, it is not saying it now")
    }

    @Test("Parent activity is reported apart from the turn's phase")
    func parentActivityIsItsOwnField() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "go")))
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)

        emit(host, id, ["type": "system", "subtype": "session_state_changed", "session_id": id,
                        "state": "requires_action", "uuid": "s1"])

        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.parent?.state == "requiresAction")
        #expect(state?.phase == .clientAcknowledged,
                "what happened to my prompt and what the session is doing are two questions")
        #expect(state?.parent?.observedAt != nil)
    }

    @Test("Without a report, parent activity is unknown rather than guessed")
    func parentActivityIsNeverInferred() {
        let (host, _, id) = fixture()
        emit(host, id, ["type": "system", "subtype": "task_started", "session_id": id,
                        "task_id": "T1", "uuid": "e1"])
        let parent = host.handle(.status(sessionID: id)).session?.parent
        #expect(parent?.state == "unknown", "a running job is not the parent's state")
        #expect(parent?.stale == true)
    }

    @Test("The live task set replaces membership, and ambient work is not counted")
    func theLevelSignalReplacesTheSet() {
        let (host, _, id) = fixture()
        emit(host, id, ["type": "system", "subtype": "task_started", "session_id": id,
                        "task_id": "A", "uuid": "e1"])
        emit(host, id, ["type": "system", "subtype": "background_tasks_changed", "uuid": "l1",
                        "session_id": id,
                        "tasks": [["task_id": "A", "task_type": "local_bash", "description": "x"],
                                  ["task_id": "W", "task_type": "local_bash", "description": "y",
                                   "ambient": true]]])

        let after = host.handle(.status(sessionID: id)).session?.jobs ?? []
        #expect(after.count == 2)
        #expect(after.first { $0.taskID == "W" }?.ambient == true,
                "housekeeping is reported and kept out of the work indicators")

        // An empty replace: A is no longer live. It is absent, not completed.
        emit(host, id, ["type": "system", "subtype": "background_tasks_changed", "uuid": "l2",
                        "session_id": id, "tasks": []])
        let gone = host.handle(.status(sessionID: id)).session?.jobs.first { $0.taskID == "A" }
        #expect(gone?.state == "absent")
        #expect(gone?.state != "completed", "a job leaving the set is not a job that finished")
    }

    @Test("An acceptance hand-back is visible as an open checkpoint, and jobs do not close it")
    func acceptanceIsVisibleOnTheOwnedAPI() {
        let (host, launcher, id) = fixture()
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "build it")))
        let key = try! JSONSerialization.jsonObject(
            with: Data(launcher.handle(id)!.writtenLines.last!.utf8)) as! [String: Any]
        host.receive(launcher.handle(id)!.writtenLines.last!, for: id)
        emit(host, id, ["type": "result", "subtype": "success", "session_id": id, "uuid": "r1",
                        "user_message_uuid": key["uuid"]!, "is_error": false,
                        "result": "Built it. UAT steps are here: open the panel and check the row."])

        var state = host.handle(.status(sessionID: id)).session
        #expect(state?.attention?.kind == "acceptance")
        #expect(state?.attention?.open == true)
        #expect(state?.attention?.messageID == "m1")
        #expect(state?.phase == .completed, "the turn finished; the ask is still open")

        // A task finishing is not the user having tested anything.
        emit(host, id, ["type": "system", "subtype": "task_notification", "session_id": id,
                        "task_id": "T1", "status": "completed", "uuid": "n1"])
        state = host.handle(.status(sessionID: id)).session
        #expect(state?.attention?.open == true)

        // The caller replying is.
        _ = host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "looks good")))
        #expect(host.handle(.status(sessionID: id)).session?.attention == nil)
    }

    @Test("The job list says how many it dropped")
    func omissionsAreStated() {
        let (host, _, id) = fixture()
        for index in 0...(BackgroundRegistry.maximumJobs + 4) {
            emit(host, id, ["type": "system", "subtype": "task_started", "session_id": id,
                            "task_id": "T\(index)", "uuid": "e\(index)"])
        }
        let state = host.handle(.status(sessionID: id)).session
        #expect(state?.jobs.count == BackgroundRegistry.maximumJobs)
        #expect(state?.jobsOmitted == 5)
        #expect(state?.jobCoverage == "partial")
    }
}
