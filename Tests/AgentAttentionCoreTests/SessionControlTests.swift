import Foundation
import Testing
@testable import AgentAttentionCore

extension BridgeAuthorization {
    /// A person approved it. Test-only shorthand.
    static let person = BridgeAuthorization(confirmed: true, statement: "the user said go ahead", via: "test")
}

extension BridgeRequest.SendRequest {
    /// The suites written before authorization existed send as a person who approved each prompt.
    /// The rule that a send needs one is tested on its own, below.
    init(sessionID: String, messageID: String, prompt: String) {
        self.init(sessionID: sessionID, messageID: messageID, prompt: prompt, authorization: .person)
    }
}

extension BridgeRequest {
    static func stop(sessionID: String) -> BridgeRequest {
        .stop(sessionID: sessionID, authorization: .person)
    }
}

/// A launcher that records fresh starts and resumes apart, because telling them apart is the point.
final class RecordingLauncher: BridgeClientLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var started: [String] = []
    private(set) var resumed: [String] = []
    private(set) var handles: [String: FakeHandle] = [:]
    var failResume = false
    var nextPID: Int32 = 7100

    private func make(_ sessionID: String) -> FakeHandle {
        nextPID += 1
        let handle = FakeHandle(pid: nextPID)
        handles[sessionID] = handle
        return handle
    }

    func launch(sessionID: String, cwd: String, model: String?,
                onLine: @escaping (String) -> Void,
                onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        lock.lock(); defer { lock.unlock() }
        started.append(sessionID)
        return make(sessionID)
    }

    func resume(sessionID: String, cwd: String, model: String?,
                onLine: @escaping (String) -> Void,
                onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        lock.lock(); defer { lock.unlock() }
        if failResume { throw NSError(domain: "test", code: 2) }
        resumed.append(sessionID)
        return make(sessionID)
    }

    func handle(_ sessionID: String) -> FakeHandle? {
        lock.lock(); defer { lock.unlock() }
        return handles[sessionID]
    }
}

/// A client that counts how often it is asked to stop, and never goes.
final class CountingHandle: BridgeClientHandle, @unchecked Sendable {
    let pid: Int32 = 7300
    private let lock = NSLock()
    private var count = 0
    var terminations: Int { lock.lock(); defer { lock.unlock() }; return count }
    var isRunning: Bool { true }
    func write(line: String) -> Bool { true }
    func terminate() { lock.lock(); count += 1; lock.unlock() }
}

final class CountingLauncher: BridgeClientLaunching, @unchecked Sendable {
    private(set) var handle: CountingHandle?
    func launch(sessionID: String, cwd: String, model: String?,
                onLine: @escaping (String) -> Void,
                onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        let made = CountingHandle()
        handle = made
        return made
    }
}

/// What Warden observes, with no disk, registry or terminal behind it.
final class FakeObserved: ObservedSessionSource, @unchecked Sendable {
    private let lock = NSLock()
    var records: [String: ObservedSessionRecord] = [:]
    var summaries: [StatusReport.SessionSummary] = []
    var contexts: [String: SessionContextAnswer] = [:]
    var transcripts: Set<String> = []
    /// Live Claude processes per conversation. `nil` models a registry that cannot be read.
    var holders: [String: [ObservedHolder]]? = [:]
    var alive: Set<Int32> = []
    var exitsWhenAsked = true
    var confirmsIdentity = true
    /// Runs while an exit is being requested — where a concurrent request would land.
    var duringExitRequest: (() -> Void)?
    private(set) var exitRequests: [Int32] = []
    private(set) var focused: [String] = []

    func rows() -> ObservedRows { ObservedRows(sessions: summaries, trustworthy: true) }
    func record(sessionID: String) -> ObservedSessionRecord? { records[sessionID] }

    func context(sessionID: String) -> SessionContextAnswer {
        contexts[sessionID] ?? SessionContextAnswer(
            sessionID: sessionID, identity: records[sessionID] == nil ? .notTracked : .verifiedLive,
            process: "alive", attention: .fixture(), context: nil, generatedAt: Date())
    }

    func transcriptExists(sessionID: String) -> Bool { transcripts.contains(sessionID) }

    func foreignHolders(sessionID: String, excluding pids: Set<Int32>) -> [ObservedHolder]? {
        lock.lock(); defer { lock.unlock() }
        guard let holders else { return nil }
        return (holders[sessionID] ?? []).filter { !pids.contains($0.pid) }
    }

    func processState(pid: Int32, startedAt: Double) -> LivenessVerdict {
        lock.lock(); defer { lock.unlock() }
        return alive.contains(pid) ? .alive : .dead
    }

    func requestExit(pid: Int32, startedAt: Double) -> Bool {
        duringExitRequest?()
        lock.lock(); defer { lock.unlock() }
        guard confirmsIdentity else { return false }
        exitRequests.append(pid)
        if exitsWhenAsked {
            alive.remove(pid)
            for key in holders?.keys.map({ $0 }) ?? [] {
                holders?[key]?.removeAll { $0.pid == pid }
            }
        }
        return true
    }

    func focus(sessionID: String) -> BridgeResponse {
        lock.lock(); defer { lock.unlock() }
        focused.append(sessionID)
        return BridgeResponse(ok: true)
    }

    /// The user types /exit in the tab.
    func userExits(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        alive.remove(pid)
        for key in holders?.keys.map({ $0 }) ?? [] { holders?[key]?.removeAll { $0.pid == pid } }
    }

    func setHolders(_ value: [String: [ObservedHolder]]?) {
        lock.lock(); defer { lock.unlock() }
        holders = value
    }
}

extension SessionContextAnswer.Attention {
    static func fixture(certainty: String = "none", reason: String? = nil,
                        caveats: [String] = []) -> Self {
        .init(known: true, certainty: certainty, kind: nil, reason: reason, waitingSeconds: nil,
              occurrences: nil, snoozed: nil, queueIsFresh: true, appIsRunning: true,
              queueAgeSeconds: 1, unprocessedEvents: 0, caveats: caveats)
    }
}

func observedRow(_ id: String, name: String = "atlas", state: String = "awaitingUser",
                 attention: String = "waiting", cwd: String = "/w/atlas",
                 age: Int = 5) -> StatusReport.SessionSummary {
    StatusReport.SessionSummary(
        sessionID: id, displayID: String(id.prefix(8)), project: name, cwd: cwd, state: state,
        terminal: "Ghostty", tty: "/dev/ttys004", lastEventAgeSeconds: age, waiting: attention == "waiting",
        process: "alive", clickTarget: "exactTab", openLabel: "Open", displayName: name,
        branchAvailability: "read", hookCoverage: true, attention: attention)
}

@Suite("Authorising what changes a session")
struct SessionAuthorizationTests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func started(_ audit: BridgeAuditRecording? = nil) -> (BridgeHost, FakeLauncher, String) {
        let launcher = FakeLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch], audit: audit)
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        return (host, launcher, id)
    }

    @Test("A send without a confirmed authorization is refused before anything is written", arguments: [
        nil,
        BridgeAuthorization(confirmed: false, statement: "go"),
        BridgeAuthorization(confirmed: true, statement: "   "),
        BridgeAuthorization(confirmed: true, statement: "line one\nline two"),
        BridgeAuthorization(confirmed: true, statement: String(repeating: "x", count: 501)),
    ] as [BridgeAuthorization?])
    func unauthorisedSendWritesNothing(_ authorization: BridgeAuthorization?) {
        let (host, launcher, id) = started()
        let answer = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "delete it",
                                             authorization: authorization)))
        #expect(answer.ok == false)
        #expect(answer.error?.code == .authorizationRequired)
        #expect(launcher.handle(id)?.writtenLines.isEmpty == true)
        // Not even remembered: the same id with a real authorization is a first send, not a retry.
        let retried = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "delete it",
                                              authorization: .person)))
        #expect(retried.ok)
        #expect(launcher.handle(id)?.writtenLines.count == 1)
    }

    @Test("A stop without a confirmed authorization stops nothing")
    func unauthorisedStopStopsNothing() {
        let (host, launcher, id) = started()
        let answer = host.handle(.stop(sessionID: id, authorization: nil))
        #expect(answer.error?.code == .authorizationRequired)
        #expect(launcher.handle(id)?.terminated == false)
        #expect(host.handle(.status(sessionID: id)).session?.phase == .accepted)
    }

    @Test("A second stop asks nothing more of a client that is already stopping")
    func secondStopSignalsNothing() {
        let launcher = CountingLauncher()
        let host = BridgeHost(launcher: launcher, approvedRoots: [scratch])
        let id = host.handle(.start(.init(requestID: "r1", cwd: scratch))).session!.sessionID
        #expect(host.handle(.stop(sessionID: id)).session?.phase == .stopping)
        #expect(host.handle(.stop(sessionID: id)).session?.phase == .stopping)
        #expect(launcher.handle?.terminations == 1)
    }

    @Test("A stop frame from an older client decodes, and is refused for want of authorization")
    func olderStopFrameIsRefused() throws {
        let (host, launcher, id) = started()
        let frame = Data(#"{"stop":{"sessionID":"\#(id)"}}"#.utf8)
        let request = try JSONCoding.decoder.decode(BridgeRequest.self, from: frame)
        #expect(host.handle(request).error?.code == .authorizationRequired)
        #expect(launcher.handle(id)?.terminated == false)
    }

    @Test("Every change is written to the audit log with who vouched for it — never what was said")
    func auditRecordsWhoAndWhatHappened() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = BridgeAuditLog(url: file)
        let (host, _, id) = started(log)
        _ = host.handle(.send(.init(sessionID: id, messageID: "m1", prompt: "the secret plan",
                                    authorization: .person)))
        _ = host.handle(.send(.init(sessionID: id, messageID: "m2", prompt: "again", authorization: nil)))
        _ = host.handle(.status(sessionID: id))
        _ = host.handle(.stop(sessionID: id))

        let entries = log.entries()
        #expect(entries.map(\.operation) == ["start", "send", "send", "stop"])
        #expect(entries[1].authorized && entries[1].statement == "the user said go ahead")
        #expect(entries[1].promptFingerprint == BridgeHost.fingerprint("the secret plan"))
        #expect(entries[2].ok == false && entries[2].error == "authorizationRequired")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("the secret plan"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("The audit log is bounded, keeping one older file rather than growing for ever")
    func auditLogRotates() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("1"))
        }
        let log = BridgeAuditLog(url: file, maximumBytes: 600)
        for index in 0..<20 {
            log.append(BridgeAuditEntry(at: Date(), operation: "send", sessionID: "s\(index)", key: nil,
                                        promptFingerprint: nil, authorized: true, statement: "ok",
                                        via: nil, ok: true, error: nil, outcome: nil))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        #expect(size <= 600)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("1").path))
    }
}

@Suite("Adopting a session that was started in a terminal")
struct SessionAdoptionTests {
    private let scratch = BridgeHost.resolve(FileManager.default.temporaryDirectory.path)!
    private let conversation = "4a1f2c3d-0000-4000-8000-00000000abcd"
    private let original: Int32 = 5151

    private func fixture(roots: [String]? = nil, activity: String = "awaitingUser",
                         background: Int = 0)
        -> (BridgeHost, RecordingLauncher, FakeObserved) {
        let launcher = RecordingLauncher()
        let observed = FakeObserved()
        observed.records[conversation] = ObservedSessionRecord(
            sessionID: conversation, cwd: scratch, displayName: "atlas", pid: original,
            pidStartedAt: 1_789_000_000, tty: "/dev/ttys004", activity: activity,
            backgroundRunning: background)
        observed.summaries = [observedRow(conversation, cwd: scratch)]
        observed.transcripts = [conversation]
        observed.alive = [original]
        observed.holders = [conversation: [ObservedHolder(pid: original, startedAt: 1_789_000_000)]]
        let host = BridgeHost(launcher: launcher, approvedRoots: roots ?? [scratch], observed: observed)
        host.adoptionExitWait = 0.2
        return (host, launcher, observed)
    }

    private func adopt(_ host: BridgeHost, _ action: BridgeRequest.AdoptRequest.Action,
                       request: String = "adopt-1", session: String? = nil,
                       detach: BridgeRequest.AdoptRequest.Detach? = nil,
                       authorization: BridgeAuthorization? = .person) -> BridgeResponse {
        host.handle(.adopt(.init(requestID: request, sessionID: session ?? conversation,
                                 action: action, detach: detach, authorization: authorization)))
    }

    @Test("Preparing pins the exact conversation and leaves the original running and untouched")
    func prepareTouchesNothing() {
        let (host, launcher, observed) = fixture()
        let answer = adopt(host, .prepare)
        #expect(answer.ok)
        #expect(answer.adoption?.phase == .awaitingDetach)
        #expect(answer.adoption?.sessionID == conversation)
        #expect(answer.adoption?.originalPID == original)
        #expect(answer.adoption?.nextStep.contains("/exit") == true)
        #expect(observed.exitRequests.isEmpty)
        #expect(launcher.resumed.isEmpty && launcher.started.isEmpty)
    }

    @Test("Nothing that cannot be proven safe is reserved", arguments: ["unobserved", "unidentified",
                                                                        "unapproved", "noTranscript"])
    func refusalsReserveNothing(_ why: String) {
        let (host, _, observed) = fixture(roots: why == "unapproved" ? ["/nonexistent-root/elsewhere"] : nil)
        switch why {
        case "unobserved": observed.records = [:]
        case "unidentified": observed.records[conversation]?.pid = nil
        case "noTranscript": observed.transcripts = []
        default: break
        }
        let answer = adopt(host, .prepare)
        #expect(answer.ok == false)
        #expect(answer.error?.code == (why == "unapproved" ? .directoryNotApproved : .notAdoptable))
        #expect(host.handle(.sessions).adoptions?.isEmpty == true)
    }

    @Test("Adoption without a confirmed authorization is refused at every step",
          arguments: [BridgeRequest.AdoptRequest.Action.prepare, .complete, .cancel])
    func adoptionNeedsAuthorization(_ action: BridgeRequest.AdoptRequest.Action) {
        let (host, launcher, observed) = fixture()
        if action != .prepare { _ = adopt(host, .prepare) }
        observed.userExits(original)
        let answer = adopt(host, action, authorization: BridgeAuthorization(confirmed: false, statement: "x"))
        #expect(answer.error?.code == .authorizationRequired)
        #expect(launcher.resumed.isEmpty)
    }

    @Test("Completing while the original is still running is refused, and the reservation is kept")
    func completeWaitsForTheOriginal() {
        let (host, launcher, _) = fixture()
        _ = adopt(host, .prepare)
        let answer = adopt(host, .complete)
        #expect(answer.ok == false)
        #expect(answer.error?.code == .writerConflict)
        #expect(answer.adoption?.phase == .awaitingDetach)
        #expect(launcher.resumed.isEmpty)
    }

    @Test("Once the original has exited, the same conversation is resumed under Warden")
    func completeResumesTheSameConversation() {
        let (host, launcher, observed) = fixture()
        _ = adopt(host, .prepare)
        observed.userExits(original)
        let answer = adopt(host, .complete)
        #expect(answer.ok)
        #expect(answer.adoption?.phase == .adopted)
        #expect(launcher.resumed == [conversation])
        #expect(launcher.started.isEmpty)
        #expect(answer.session?.sessionID == conversation)
        #expect(answer.session?.adoptedFrom == "adopt-1")
        // Owned now: a send is accepted and written to the resumed client.
        #expect(host.handle(.send(.init(sessionID: conversation, messageID: "m1", prompt: "carry on"))).ok)
        #expect(launcher.handle(conversation)?.writtenLines.count == 1)
    }

    @Test("Completing twice is the same adoption, not a second client")
    func completeIsIdempotent() {
        let (host, launcher, observed) = fixture()
        _ = adopt(host, .prepare)
        observed.userExits(original)
        _ = adopt(host, .complete)
        let again = adopt(host, .complete)
        #expect(again.ok)
        #expect(launcher.resumed.count == 1)
    }

    @Test("A request id means one adoption: reusing it for another session, or a second id for the same one, is a conflict")
    func requestIdsAreIdempotent() {
        let (host, _, _) = fixture()
        let first = adopt(host, .prepare)
        let retry = adopt(host, .prepare)
        #expect(retry.ok && retry.adoption?.createdAt == first.adoption?.createdAt)
        #expect(adopt(host, .prepare, session: "5b2e0000-0000-4000-8000-00000000beef").error?.code
                == .idempotencyConflict)
        #expect(adopt(host, .prepare, request: "adopt-2").error?.code == .idempotencyConflict)
    }

    @Test("Another process holding the conversation blocks completion, and so does a registry nobody could read")
    func otherWritersBlockCompletion() {
        let (host, launcher, observed) = fixture()
        _ = adopt(host, .prepare)
        observed.userExits(original)
        observed.setHolders([conversation: [ObservedHolder(pid: 6262, startedAt: 1)]])
        #expect(adopt(host, .complete).error?.code == .writerConflict)
        observed.setHolders(nil)
        let unreadable = adopt(host, .complete)
        #expect(unreadable.error?.code == .writerConflict)
        #expect(unreadable.adoption?.blockers.first?.contains("registry") == true)
        #expect(launcher.resumed.isEmpty)
    }

    @Test("Detach terminate asks an idle original to exit once, and completes once the exit is seen")
    func terminateAsksOnce() {
        let (host, launcher, observed) = fixture()
        let prepared = adopt(host, .prepare, detach: .terminate)
        #expect(prepared.ok)
        #expect(observed.exitRequests == [original])
        #expect(prepared.adoption?.phase == .ready)
        _ = adopt(host, .prepare, detach: .terminate)
        #expect(observed.exitRequests == [original])
        #expect(adopt(host, .complete).ok)
        #expect(launcher.resumed == [conversation])
    }

    @Test("A client that does not leave when asked is never asked twice or forced")
    func terminateNeverInsists() {
        let (host, launcher, observed) = fixture()
        observed.exitsWhenAsked = false
        let prepared = adopt(host, .prepare, detach: .terminate)
        #expect(prepared.adoption?.phase == .detaching)
        _ = adopt(host, .prepare, detach: .terminate)
        #expect(observed.exitRequests == [original])
        #expect(adopt(host, .complete).error?.code == .writerConflict)
        #expect(launcher.resumed.isEmpty)
    }

    @Test("Detach terminate will not interrupt a working turn, background work, or a process it cannot confirm",
          arguments: ["working", "background", "unconfirmed"])
    func terminateRefusesBusySessions(_ why: String) {
        let (host, _, observed) = fixture(activity: why == "working" ? "working" : "awaitingUser",
                                          background: why == "background" ? 1 : 0)
        if why == "unconfirmed" { observed.confirmsIdentity = false }
        let answer = adopt(host, .prepare, detach: .terminate)
        #expect(answer.ok == false)
        #expect(answer.error?.code == .notAdoptable)
        #expect(answer.adoption?.phase == .awaitingDetach)
        #expect(observed.exitRequests.isEmpty)
    }

    @Test("A cancel that lands while an exit is being requested says a signal went out")
    func cancelDuringTerminateIsTruthful() {
        let (host, launcher, observed) = fixture()
        observed.exitsWhenAsked = false
        final class Box: @unchecked Sendable { var answer: BridgeResponse? }
        let box = Box()
        observed.duringExitRequest = { box.answer = adopt(host, .cancel) }
        _ = adopt(host, .prepare, detach: .terminate)
        #expect(box.answer?.adoption?.phase == .cancelled)
        #expect(box.answer?.adoption?.nextStep.contains("asked to exit") == true)
        #expect(launcher.resumed.isEmpty)
    }

    @Test("Cancelling leaves the session as it was, and a cancelled adoption cannot be completed")
    func cancelLeavesItAlone() {
        let (host, launcher, observed) = fixture()
        _ = adopt(host, .prepare)
        #expect(adopt(host, .cancel).adoption?.phase == .cancelled)
        observed.userExits(original)
        #expect(adopt(host, .complete).ok == false)
        #expect(launcher.resumed.isEmpty)
        #expect(observed.exitRequests.isEmpty)
    }

    @Test("A session only observed is never sent to, prepared or not")
    func observedIsNeverDriven() {
        let (host, _, _) = fixture()
        #expect(host.handle(.send(.init(sessionID: conversation, messageID: "m", prompt: "hi"))).error?.code
                == .notOwned)
        _ = adopt(host, .prepare)
        #expect(host.handle(.send(.init(sessionID: conversation, messageID: "m", prompt: "hi"))).error?.code
                == .notOwned)
        #expect(host.handle(.stop(sessionID: conversation)).error?.code == .notOwned)
    }

    @Test("An adopted session refuses a send while another process holds the same conversation")
    func sendChecksForOtherWriters() {
        let (host, launcher, observed) = fixture()
        _ = adopt(host, .prepare)
        observed.userExits(original)
        _ = adopt(host, .complete)
        let own = launcher.handle(conversation)!.pid
        // Warden's own client is in the registry too, and is not a second writer.
        observed.setHolders([conversation: [ObservedHolder(pid: own, startedAt: nil)]])
        #expect(host.handle(.send(.init(sessionID: conversation, messageID: "m1", prompt: "one"))).ok)
        // The user resumes the conversation in a terminal as well.
        observed.setHolders([conversation: [ObservedHolder(pid: own, startedAt: nil),
                                            ObservedHolder(pid: 8080, startedAt: nil)]])
        let refused = host.handle(.send(.init(sessionID: conversation, messageID: "m2", prompt: "two")))
        #expect(refused.error?.code == .writerConflict)
        #expect(launcher.handle(conversation)?.writtenLines.count == 1)
    }

    @Test("A resumed client that starts a copy instead of continuing the conversation is stopped, and says so")
    func forkedResumeIsStopped() {
        let (host, launcher, observed) = fixture()
        _ = adopt(host, .prepare)
        observed.userExits(original)
        _ = adopt(host, .complete)
        host.receive(#"{"type":"system","subtype":"init","session_id":"99999999-0000-4000-8000-000000000000"}"#,
                     for: conversation)
        let state = host.handle(.status(sessionID: conversation)).session
        #expect(state?.phase == .failed)
        #expect(host.handle(.send(.init(sessionID: conversation, messageID: "m", prompt: "x"))).ok == false)
        // Terminated off the lock; give it a moment.
        let deadline = Date().addingTimeInterval(5)
        while launcher.handle(conversation)?.terminated == false && Date() < deadline { usleep(10_000) }
        #expect(launcher.handle(conversation)?.terminated == true)
    }

    @Test("A resume that cannot start leaves the adoption ready to try again")
    func failedResumeCanBeRetried() {
        let (host, launcher, observed) = fixture()
        _ = adopt(host, .prepare)
        observed.userExits(original)
        launcher.failResume = true
        let failed = adopt(host, .complete)
        #expect(failed.error?.code == .clientUnavailable)
        #expect(host.handle(.status(sessionID: conversation)).session == nil)
        launcher.failResume = false
        #expect(adopt(host, .complete).ok)
    }

    @Test("Adoption is audited with its request id and outcome")
    func adoptionIsAudited() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = BridgeAuditLog(url: file)
        let observed = FakeObserved()
        observed.records[conversation] = ObservedSessionRecord(sessionID: conversation, cwd: scratch,
                                                               pid: original, pidStartedAt: 1, activity: "awaitingUser")
        observed.transcripts = [conversation]
        let host = BridgeHost(launcher: RecordingLauncher(), approvedRoots: [scratch], observed: observed, audit: log)
        _ = adopt(host, .prepare)
        _ = adopt(host, .complete)
        #expect(log.entries().map(\.operation) == ["adopt.prepare", "adopt.complete"])
        #expect(log.entries().allSatisfy { $0.key == "adopt-1" && $0.authorized })
        #expect(log.entries().last?.outcome == "adopted")
    }
}

@Suite("Reading sessions through the bridge")
struct SessionReadingTests {
    private let scratch = FileManager.default.temporaryDirectory.path
    private let watched = "6c3d0000-0000-4000-8000-00000000cafe"

    private func fixture() -> (BridgeHost, FakeObserved) {
        let observed = FakeObserved()
        observed.records[watched] = ObservedSessionRecord(sessionID: watched, cwd: "/w/atlas", pid: 42,
                                                          pidStartedAt: 1, activity: "awaitingUser")
        observed.summaries = [observedRow(watched)]
        let messages = (0..<20).map {
            SessionContext.Message(role: $0 % 2 == 0 ? "user" : "assistant", at: Date(),
                                   excerpt: "message \($0) " + String(repeating: "word ", count: 200),
                                   truncated: false)
        }
        observed.contexts[watched] = SessionContextAnswer(
            sessionID: watched, identity: .verifiedLive, displayName: "atlas", process: "alive",
            attention: .fixture(certainty: "waiting", reason: "Asked you a question",
                                caveats: ["A caveat worth repeating."]),
            context: SessionContext(sessionID: watched, availability: .read, readAt: Date(),
                                    messages: messages, latestUserRequest: messages[18],
                                    latestAssistantResponse: messages[19]),
            generatedAt: Date())
        return (BridgeHost(launcher: FakeLauncher(), approvedRoots: [scratch], observed: observed), observed)
    }

    @Test("Listing shows owned and observed sessions apart")
    func listingKeepsOwnershipApart() {
        let (host, _) = fixture()
        let owned = host.handle(.start(.init(requestID: "r", cwd: scratch))).session!.sessionID
        let list = host.handle(.sessions)
        #expect(list.ok)
        #expect(list.sessions?.map(\.sessionID) == [owned])
        #expect(list.observed?.map(\.sessionID) == [watched])
        #expect(list.observedTrustworthy == true)
    }

    @Test("Reading needs no authorization, and an observed session answers status as observed")
    func readsAreOpen() {
        let (host, _) = fixture()
        let status = host.handle(.status(sessionID: watched))
        #expect(status.ok && status.session == nil && status.observed?.first?.sessionID == watched)
        #expect(host.handle(.context(sessionID: watched, maxMessages: nil)).ok)
        #expect(host.handle(.summary(sessionID: watched)).ok)
    }

    @Test("Context is bounded to what was asked for, and a session nobody knows gets nothing")
    func contextIsBounded() {
        let (host, _) = fixture()
        #expect(host.handle(.context(sessionID: watched, maxMessages: 3)).context?.context?.messages.count == 3)
        #expect(host.handle(.context(sessionID: watched, maxMessages: 500)).context?.context?.messages.count
                == SessionContextReader.maximumMessages)
        let unknown = host.handle(.context(sessionID: "7d4e0000-0000-4000-8000-00000000dead", maxMessages: 3))
        #expect(unknown.error?.code == .notOwned && unknown.context == nil)
    }

    @Test("A summary is built from facts that each name their source, and stays bounded")
    func summaryIsGrounded() throws {
        let (host, _) = fixture()
        let summary = try #require(host.handle(.summary(sessionID: watched)).summary)
        #expect(summary.headline.hasPrefix("atlas is waiting for you"))
        #expect(!summary.facts.isEmpty)
        #expect(summary.facts.allSatisfy { ["queue", "transcript", "bridge", "process"].contains($0.source) })
        #expect(summary.facts.contains { $0.source == "transcript" && $0.statement.hasPrefix("Last reply") })
        #expect(summary.facts.allSatisfy { $0.statement.count <= 400 })
        #expect(summary.caveats == ["A caveat worth repeating."])
        #expect(host.handle(.summary(sessionID: "7d4e0000-0000-4000-8000-00000000dead")).error?.code == .notOwned)
    }

    @Test("Focusing an observed session goes only through the app's linked-tab path")
    func observedFocusIsDelegated() {
        let (host, observed) = fixture()
        #expect(host.handle(.focus(sessionID: watched)).ok)
        #expect(observed.focused == [watched])
        // An owned background session still has no terminal of its own, and says so.
        let owned = host.handle(.start(.init(requestID: "r", cwd: scratch))).session!.sessionID
        #expect(host.handle(.focus(sessionID: owned)).ok == false)
        #expect(observed.focused == [watched])
    }
}

@Suite("Which project roots the bridge will work in")
struct BridgeRootTests {
    @Test("Roots that would grant everything are refused", arguments: ["/", "/Users", "/private/tmp", "/tmp", "~", "~/.."])
    func broadRootsAreRefused(_ root: String) {
        #expect(BridgeSettings.acceptableRoots([root]).isEmpty)
    }

    @Test("A project directory is an acceptable root")
    func projectRootIsAccepted() {
        let project = FileManager.default.temporaryDirectory.path
        #expect(BridgeSettings.acceptableRoots([project]) == [BridgeHost.normalise(project)])
    }

    @Test("Approvals read from settings take effect on the next request, without a restart")
    func settingsAreReadPerRequest() {
        let project = FileManager.default.temporaryDirectory.path
        final class Roots: @unchecked Sendable { var value: [String] = [] }
        let roots = Roots()
        let host = BridgeHost(launcher: FakeLauncher(), approvedRoots: [], rootsProvider: { roots.value })
        #expect(host.handle(.start(.init(requestID: "a", cwd: project))).error?.code == .directoryNotApproved)
        roots.value = [project]
        #expect(host.handle(.start(.init(requestID: "b", cwd: project))).ok)
        roots.value = ["/"]
        #expect(host.handle(.start(.init(requestID: "c", cwd: project))).error?.code == .directoryNotApproved)
    }

    @Test("No settings file means the bridge runs and may start nothing; a broken one grants nothing")
    func settingsDefaults() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-\(UUID().uuidString).json")
        #expect(BridgeSettings.load(from: missing) == BridgeSettings(enabled: true, approvedRoots: []))
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).json")
        try Data(#"{"approvedRoots": "/w"#.utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        #expect(BridgeSettings.load(from: broken).approvedRoots.isEmpty)
        let off = FileManager.default.temporaryDirectory.appendingPathComponent("off-\(UUID().uuidString).json")
        try Data(#"{"enabled": false}"#.utf8).write(to: off)
        defer { try? FileManager.default.removeItem(at: off) }
        #expect(BridgeSettings.load(from: off).enabled == false)
    }
}

@Suite("Resuming a conversation")
struct ResumeCommandTests {
    @Test("A resumed client continues the named conversation rather than starting one under its id")
    func resumeArguments() {
        let arguments = ClaudeStreamLauncher.arguments(sessionID: "S-1", model: nil, withoutTools: false,
                                                       resume: true)
        let index = arguments.firstIndex(of: "--resume")
        #expect(index.map { arguments[$0 + 1] } == "S-1")
        #expect(!arguments.contains("--session-id"))
        #expect(!arguments.contains("--fork-session"))
        #expect(ClaudeStreamLauncher.arguments(sessionID: "S-1", model: nil, withoutTools: false)
            .contains("--session-id"))
    }

    @Test("A client the bridge starts is its own session, not a child of whatever started the host")
    func clientsDropInheritedSessionMarkers() {
        let inherited = ["CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "x",
                         "CLAUDE_CODE_MESSAGING_TOKEN": "secret", "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8000",
                         "PATH": "/usr/bin", "HOME": "/Users/alex"]
        let clean = ClaudeStreamLauncher.independentEnvironment(inherited)
        #expect(clean == ["CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8000", "PATH": "/usr/bin", "HOME": "/Users/alex"])
    }

    @Test("A visible tab can host a resumed conversation too")
    func visibleResume() throws {
        let plan = try #require(VisibleSessionPlan(sessionID: "S-1", cwd: "/private/tmp", model: nil,
                                                   claudeExecutable: "/bin/claude", relayExecutable: "/bin/relay",
                                                   inbox: "/private/tmp/i", outbox: "/private/tmp/o",
                                                   withoutTools: false, resume: true))
        #expect(plan.command.hasSuffix(" --resume"))
    }

    @Test("A launcher that cannot resume refuses rather than starting a fresh session")
    func resumeIsNeverAFreshStart() {
        #expect(throws: BridgeLaunchError.self) {
            _ = try FakeLauncher().resume(sessionID: "S", cwd: "/", model: nil, onLine: { _ in }, onExit: { _ in })
        }
    }
}
