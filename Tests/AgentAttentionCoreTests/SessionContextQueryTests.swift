import Foundation
import Testing
@testable import AgentAttentionCore

/// Identity before contents, and one trust model shared with the rest of the app.
///
/// The failure this suite exists to prevent: a conversation being shown for an id the app cannot
/// vouch for, under a confident "nothing is being asked of you right now" that was decided by
/// `session != nil` rather than by whether anything is actually known.
@Suite("Session context query")
final class SessionContextQueryTests {
    private let paths: AppPaths
    private let store: EventStore
    private let claudeHome: URL
    private let projects: URL

    init() throws {
        paths = try Fixture.temporaryPaths()
        store = EventStore(paths: paths)
        claudeHome = paths.root.appendingPathComponent("claude-home")
        projects = claudeHome.appendingPathComponent("projects/-w-alpha")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: paths.root)
    }

    private func writeTranscript(_ sessionID: String, text: String) throws {
        let record: [String: Any] = [
            "type": "user", "sessionId": sessionID, "userType": "external",
            "timestamp": "2026-09-06T10:00:00.000Z",
            "message": ["role": "user", "content": text],
        ]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        try Data((line + "\n").utf8).write(to: projects.appendingPathComponent("\(sessionID).jsonl"))
    }

    /// A queue with one session, saved the way the app saves it, plus a live app presence.
    private func seed(sessionID: String, activity: SessionActivityState, withAsk: Bool = false, pid: Int32 = 4242) throws {
        let clock = TestClock(Date())
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        let identity = Fixture.identity(session: sessionID, project: "alpha", pid: pid)
        if withAsk {
            engine.ingest(Fixture.event(session: sessionID, signal: .attention, kind: .approval,
                                        detail: "Permission needed: Bash", at: clock.now, identity: identity))
        } else {
            engine.ingest(Fixture.event(session: sessionID, signal: .activity, at: clock.now,
                                        hookEvent: "PostToolUse", identity: identity))
        }
        var snapshot = engine.snapshot()
        snapshot.sessions[sessionID]?.activity = activity
        try store.save(snapshot: snapshot)
        try store.write(appStatus: AppRunStatus(pid: 4242, pidStartedAt: 1, version: "0.9.0", startedAt: Date()))
    }

    private func run(_ sessionID: String, liveness: LivenessProbing = StubLiveness()) -> SessionContextAnswer {
        SessionContextQuery.run(sessionID: sessionID, store: store, config: .default,
                                claudeHome: claudeHome, liveness: liveness)
    }

    // MARK: - Identity first

    @Test("A session the app does not track gets no contents at all")
    func untrackedSessionIsRefused() throws {
        let stranger = "cccccccc-1111-2222-3333-444444444444"
        try seed(sessionID: "sess-known-01", activity: .working)
        try writeTranscript(stranger, text: "UNTRACKED-SENTINEL")

        let answer = run(stranger)

        #expect(answer.identity == .notTracked)
        #expect(answer.context == nil, "the file exists, and it was still not opened")
        #expect(!answer.readContents)
        #expect(!answer.attention.known)
        #expect(answer.attention.caveats.contains { $0.contains("not in Agent Warden's queue") })
    }

    @Test("A tracked session with a live process is verified, and read")
    func trackedLiveSession() throws {
        try seed(sessionID: "sess-known-01", activity: .working)
        try writeTranscript("sess-known-01", text: "rework the export")

        let answer = run("sess-known-01")

        #expect(answer.identity == .verifiedLive)
        #expect(answer.process == "alive")
        #expect(answer.context?.messages.first?.excerpt == "rework the export")
    }

    @Test("A tracked session whose process is gone says so, and is not called live")
    func deadProcessIsSeparate() throws {
        try seed(sessionID: "sess-known-01", activity: .working)
        try writeTranscript("sess-known-01", text: "older conversation")
        let dead = StubLiveness()
        dead.kill(4242)

        let answer = run("sess-known-01", liveness: dead)

        #expect(answer.identity == .processGone)
        #expect(answer.context == nil, "a recycled pid could belong to something else; nothing is read")
        #expect(!answer.attention.known)
        #expect(answer.attention.caveats.contains { $0.contains("process is gone") })
    }

    @Test("A session whose process cannot be checked is unverified, not verified")
    func unverifiableProcessIsSeparate() throws {
        try seed(sessionID: "sess-known-01", activity: .working)
        try writeTranscript("sess-known-01", text: "conversation")
        let blind = StubLiveness()
        blind.deny(4242)

        let answer = run("sess-known-01", liveness: blind)
        #expect(answer.identity == .unverified)
        #expect(answer.context == nil, "an unverifiable process gets no contents")
        #expect(!answer.attention.known)
        #expect(answer.attention.caveats.contains { $0.contains("could not be pinned down") })
    }

    @Test("A session with no recorded process start cannot be verified, and is not read")
    func missingStartTimeIsUnverified() throws {
        try seed(sessionID: "sess-known-01", activity: .working)
        try writeTranscript("sess-known-01", text: "conversation")
        // A pid without the moment it started names nothing: pids are recycled within hours.
        var snapshot = try #require(store.loadSnapshot())
        snapshot.sessions["sess-known-01"]?.identity.claudePIDStartedAt = nil
        try store.save(snapshot: snapshot)

        let answer = run("sess-known-01")
        #expect(answer.identity == .unverified)
        #expect(answer.context == nil)
        #expect(!answer.attention.known)
    }

    // MARK: - The trust model is the shared one

    @Test("A session whose state is unknown is never reported as known")
    func uncertainSessionIsNotKnown() throws {
        try seed(sessionID: "sess-known-01", activity: .unknown)
        try writeTranscript("sess-known-01", text: "something")

        let answer = run("sess-known-01")

        #expect(answer.attention.certainty == "uncertain")
        #expect(!answer.attention.known, "a session != nil is not the same as knowing anything")
        #expect(answer.attention.kind == nil)
        #expect(answer.attention.caveats.contains { $0.contains("unknown, not quiet") })
    }

    @Test("A working session with nothing pending is positively known to be quiet")
    func workingSessionIsKnownQuiet() throws {
        try seed(sessionID: "sess-known-01", activity: .working)
        try writeTranscript("sess-known-01", text: "something")

        let answer = run("sess-known-01")
        #expect(answer.attention.certainty == "none")
        #expect(answer.attention.known)
        #expect(answer.attention.queueIsFresh)
        #expect(answer.attention.appIsRunning == true)
    }

    @Test("An open ask is reported with its reason and its age")
    func openAskIsReported() throws {
        try seed(sessionID: "sess-known-01", activity: .awaitingUser, withAsk: true)
        try writeTranscript("sess-known-01", text: "something")

        let answer = run("sess-known-01")
        #expect(answer.attention.certainty == "waiting")
        #expect(answer.attention.kind == "approval")
        #expect(answer.attention.reason == "Permission needed: Bash")
        #expect(answer.attention.waitingSeconds != nil)
    }

    @Test("A saved ask from an app that is not running is a record, not live certainty")
    func staleAskIsCaveated() throws {
        try seed(sessionID: "sess-known-01", activity: .awaitingUser, withAsk: true)
        try writeTranscript("sess-known-01", text: "something")
        store.clearAppStatus()          // the app is gone; the queue is only what was left behind

        let answer = run("sess-known-01")

        #expect(answer.attention.kind == "approval", "the ask is still reported — it is a real record")
        #expect(!answer.attention.known, "but it is not live certainty")
        #expect(answer.attention.appIsRunning == false)
        #expect(answer.attention.caveats.contains { $0.contains("saved record") })
    }

    @Test("Queue freshness and conversation freshness are separate facts")
    func freshnessIsNotOneNumber() throws {
        try seed(sessionID: "sess-known-01", activity: .working)
        try writeTranscript("sess-known-01", text: "something said long ago")

        let answer = run("sess-known-01")
        let context = try #require(answer.context)

        #expect(answer.attention.queueAgeSeconds != nil, "how old the queue is")
        #expect(context.readAt.timeIntervalSince1970 > 0, "when we read the transcript")
        let newest = try #require(context.messages.last?.at)
        #expect(context.readAt.timeIntervalSince(newest) > 0,
                "and how old the newest message is — reading it now does not make it recent")
    }

    @Test("Backlogged hook events are reported rather than quietly ignored")
    func spoolBacklogIsSurfaced() throws {
        try seed(sessionID: "sess-known-01", activity: .working)
        try writeTranscript("sess-known-01", text: "something")
        try store.write(event: Fixture.event(session: "sess-known-01", signal: .attention,
                                             kind: .approval, at: Date()))

        let answer = run("sess-known-01")
        #expect(answer.attention.unprocessedEvents == 1,
                "there is a hook event the queue has not seen yet, and the caller should know")
    }

    // MARK: - Still read-only

    @Test("Asking changes nothing on disk")
    func queryIsReadOnly() throws {
        try seed(sessionID: "sess-known-01", activity: .working)
        try writeTranscript("sess-known-01", text: "something")
        try store.write(event: Fixture.event(session: "sess-known-01", signal: .attention,
                                             kind: .approval, at: Date()))
        let spoolBefore = try FileManager.default.contentsOfDirectory(atPath: paths.spool.path).sorted()
        let stateBefore = try Data(contentsOf: paths.stateFile)

        _ = run("sess-known-01")
        _ = run("sess-known-01")

        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.spool.path).sorted() == spoolBefore,
                "the spool is not drained by asking a question")
        #expect(try Data(contentsOf: paths.stateFile) == stateBefore)
        #expect(!FileManager.default.fileExists(atPath: paths.logFile.path), "and nothing was logged")
    }

    @Test("A tracked session with no transcript is honest about it, and still reports attention")
    func trackedButNoTranscript() throws {
        try seed(sessionID: "sess-known-01", activity: .awaitingUser, withAsk: true)

        let answer = run("sess-known-01")

        #expect(answer.identity == .verifiedLive)
        #expect(answer.context?.availability == .noTranscript)
        #expect(answer.attention.kind == "approval",
                "a missing transcript never hides a request we do know about")
    }
}
