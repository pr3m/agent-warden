import Foundation
import Testing
@testable import AgentAttentionCore

/// The only part of the app that reads message content, and the rules it reads under.
///
/// Two failures would matter more than getting nothing at all: showing somebody a *different*
/// session's conversation, and letting a transcript excerpt behave like an alert. Most of what
/// follows is about those two.
@Suite("Session context")
struct SessionContextTests {
    private let home: URL
    private let projects: URL

    init() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-warden-context-\(UUID().uuidString)")
        projects = home.appendingPathComponent("projects/-Users-dev-alpha")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    private func write(_ sessionID: String, lines: [[String: Any]]) throws -> URL {
        let url = projects.appendingPathComponent("\(sessionID).jsonl")
        let text = lines.map { line in
            String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
        return url
    }

    private func said(_ role: String, _ text: String, session: String = "sess-alpha-01", at: String = "2026-09-06T10:00:00.000Z") -> [String: Any] {
        ["type": role, "sessionId": session, "timestamp": at,
         "message": ["role": role, "content": [["type": "text", "text": text]]]]
    }

    // MARK: - The right conversation, or none

    @Test("Only the session you asked for is read")
    func foreignRecordsAreSkipped() throws {
        _ = try write("sess-alpha-01", lines: [
            said("user", "mine"),
            said("assistant", "SOMEONE-ELSES-CONVERSATION", session: "sess-beta-02"),
            said("assistant", "also mine"),
        ])
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)

        #expect(context.availability == .read)
        #expect(context.messages.map(\.excerpt) == ["mine", "also mine"])
        #expect(!context.messages.contains { $0.excerpt.contains("SOMEONE-ELSES") })
        #expect(context.notes.contains { $0.contains("belong to another session") })
    }

    @Test("An unknown session id gets nothing, and says so")
    func unknownSession() {
        let context = SessionContextReader.read(sessionID: "sess-nothere-04", claudeHome: home)
        #expect(context.availability == .noTranscript)
        #expect(context.messages.isEmpty)
    }

    @Test("An id that is not an id never becomes a path", arguments: [
        "../../../etc/passwd", "a/b", "with space", "", "$(whoami)",
    ])
    func refusesPathLikeIDs(id: String) {
        #expect(!SessionContextReader.isPlausibleSessionID(id))
        #expect(SessionContextReader.read(sessionID: id, claudeHome: home).availability == .unknownSession)
    }

    @Test("A symlink pointing out of the projects directory is not followed")
    func symlinkEscapeIsRejected() throws {
        let secret = home.appendingPathComponent("private-key")
        try Data("SECRET-KEY-MATERIAL\n".utf8).write(to: secret)
        let link = projects.appendingPathComponent("sess-link-03.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        let context = SessionContextReader.read(sessionID: "sess-link-03", claudeHome: home)
        #expect(context.availability == .rejectedPath)
        #expect(context.messages.isEmpty)
    }

    @Test("A record with no session id at all is not implicitly ours")
    func recordsMustNameTheSession() throws {
        // A transcript file can be appended to, edited or misfiled. "No id" must not be a way to get
        // arbitrary text attributed to this session — positive identity, or nothing.
        _ = try write("sess-alpha-01", lines: [
            said("user", "mine"),
            ["type": "assistant", "timestamp": "2026-09-06T10:00:00.000Z",
             "message": ["role": "assistant", "content": [["type": "text", "text": "UNATTRIBUTED-TEXT"]]]],
        ])
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)

        #expect(context.messages.map(\.excerpt) == ["mine"])
        #expect(!context.messages.contains { $0.excerpt.contains("UNATTRIBUTED-TEXT") })
        #expect(context.notes.contains { $0.contains("belong to another session") })
    }

    @Test("A question in an unattributed record is not returned either")
    func unattributedQuestionsAreSkipped() throws {
        _ = try write("sess-alpha-01", lines: [
            ["type": "assistant",
             "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "q1", "name": "AskUserQuestion",
                 "input": ["questions": [["question": "UNATTRIBUTED-QUESTION", "options": ["a"]]]]],
             ]]],
        ])
        #expect(SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home).questions.isEmpty)
    }

    @Test("A session id that merely starts the same is a different session")
    func noPrefixMatching() throws {
        _ = try write("sess-alpha-01", lines: [
            ["type": "user", "sessionId": "sess-alpha-0123", "timestamp": "2026-09-06T10:00:00.000Z",
             "message": ["role": "user", "content": [["type": "text", "text": "LONGER-ID-TEXT"]]]],
        ])
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)
        #expect(context.messages.isEmpty, "exact id or nothing")
    }

    // MARK: - What is and is not conversation

    @Test("A plain string message body is real conversation")
    func plainStringContentIsRead() throws {
        // Observed in a live transcript: `message.content` is sometimes a bare string rather than a
        // list of typed blocks. Ignoring it drops genuine typed prompts.
        _ = try write("sess-alpha-01", lines: [
            ["type": "user", "sessionId": "sess-alpha-01", "userType": "external",
             "timestamp": "2026-09-06T10:00:00.000Z",
             "message": ["role": "user", "content": "rework the export to v3"]],
        ])
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)
        #expect(context.messages.map(\.excerpt) == ["rework the export to v3"])
        #expect(context.latestUserRequest?.excerpt == "rework the export to v3")
    }

    @Test("A user record that is really a tool result is not the latest request", arguments: [
        ["toolUseResult": "SOME-TOOL-OUTPUT"] as [String: Any],
        ["isMeta": true],
        ["isCompactSummary": true],
        ["userType": "injected"],
    ])
    func syntheticUserRecordsAreNotRequests(marker: [String: Any]) throws {
        var record: [String: Any] = [
            "type": "user", "sessionId": "sess-alpha-01", "timestamp": "2026-09-06T10:00:05.000Z",
            "message": ["role": "user", "content": "SYNTHETIC-USER-RECORD"],
        ]
        record.merge(marker) { _, new in new }
        _ = try write("sess-alpha-01", lines: [said("user", "the real request"), record])

        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)
        #expect(!context.messages.contains { $0.excerpt.contains("SYNTHETIC-USER-RECORD") })
        #expect(context.latestUserRequest?.excerpt == "the real request",
                "role alone does not make something a person's request")
    }

    @Test("An assistant record is still assistant text whatever else is on it")
    func assistantRecordsAreNotFilteredByUserMarkers() throws {
        _ = try write("sess-alpha-01", lines: [
            ["type": "assistant", "sessionId": "sess-alpha-01", "timestamp": "2026-09-06T10:00:00.000Z",
             "message": ["role": "assistant", "content": "done, schema switched"]],
        ])
        #expect(SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)
                    .latestAssistantResponse?.excerpt == "done, schema switched")
    }


    @Test("Thinking, tool inputs and tool results never appear")
    func onlyConversationIsReturned() throws {
        _ = try write("sess-alpha-01", lines: [
            ["type": "assistant", "sessionId": "sess-alpha-01", "timestamp": "2026-09-06T10:00:00.000Z",
             "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "SECRET-THINKING"],
                ["type": "text", "text": "here is what I did"],
                ["type": "tool_use", "id": "t1", "name": "Bash",
                 "input": ["command": "SECRET-COMMAND"]],
             ]]],
            ["type": "user", "sessionId": "sess-alpha-01", "timestamp": "2026-09-06T10:00:01.000Z",
             "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "SECRET-TOOL-OUTPUT"],
             ]]],
        ])
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)
        let all = context.messages.map(\.excerpt).joined(separator: "\n")

        #expect(all == "here is what I did")
        #expect(!all.contains("SECRET-THINKING"))
        #expect(!all.contains("SECRET-COMMAND"))
        #expect(!all.contains("SECRET-TOOL-OUTPUT"))
        #expect(context.messages.count == 1, "a tool result is not a user message")
    }

    @Test("A subagent's own conversation is not this session's")
    func sidechainsAreSkipped() throws {
        _ = try write("sess-alpha-01", lines: [
            said("user", "real request"),
            ["type": "assistant", "sessionId": "sess-alpha-01", "isSidechain": true,
             "message": ["role": "assistant", "content": [["type": "text", "text": "SUBAGENT-CHATTER"]]]],
        ])
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)
        #expect(context.messages.map(\.excerpt) == ["real request"])
    }

    @Test("The latest genuine request and response are attributed, not merged")
    func latestOfEach() throws {
        _ = try write("sess-alpha-01", lines: [
            said("user", "first ask", at: "2026-09-06T10:00:00.000Z"),
            said("assistant", "first answer", at: "2026-09-06T10:00:01.000Z"),
            said("user", "second ask", at: "2026-09-06T10:00:02.000Z"),
            said("assistant", "second answer", at: "2026-09-06T10:00:03.000Z"),
        ])
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)

        #expect(context.latestUserRequest?.excerpt == "second ask")
        #expect(context.latestUserRequest?.role == "user")
        #expect(context.latestAssistantResponse?.excerpt == "second answer")
        #expect(context.latestAssistantResponse?.at != nil)
    }

    // MARK: - Bounds

    @Test("Only the most recent messages come back")
    func messageCountIsBounded() throws {
        _ = try write("sess-alpha-01", lines: (0..<60).map { said("user", "message \($0)") })
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)
        #expect(context.messages.count == SessionContextReader.maximumMessages)
        #expect(context.messages.last?.excerpt == "message 59")
    }

    @Test("A very long message is cut, and says it was")
    func longMessagesAreTruncated() throws {
        _ = try write("sess-alpha-01", lines: [said("assistant", String(repeating: "x", count: 5000))])
        let message = try #require(SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home).messages.first)
        #expect(message.truncated)
        #expect(message.excerpt.count <= SessionContextReader.maximumExcerptCharacters)
        #expect(message.excerpt.hasSuffix("…"))
    }

    @Test("Reading only a tail says so, and drops the half line it opens on")
    func tailIsBoundedAndPartialLinesDropped() throws {
        let url = try write("sess-alpha-01", lines: (0..<400).map { said("user", "line \($0) " + String(repeating: "y", count: 400)) })
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home, tailBytes: 8192)

        #expect(context.tailTruncated)
        #expect(context.bytesRead <= 8192)
        #expect(context.notes.contains { $0.contains("anything older is not shown") })
        #expect(!context.messages.isEmpty, "the whole records inside the window still parse")
        #expect(FileManager.default.contents(atPath: url.path)!.count > 8192)
    }

    @Test("A transcript being appended to while we read is still a bounded read")
    func growingFileIsBounded() throws {
        let url = try write("sess-alpha-01", lines: (0..<50).map { said("user", "line \($0)") })
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home, tailBytes: 4096)
        try handle.write(contentsOf: Data(String(repeating: "z", count: 4096).utf8))
        try handle.close()
        #expect(context.bytesRead <= 4096)
    }

    @Test("Malformed lines are counted and skipped, not fatal")
    func malformedLines() throws {
        let url = projects.appendingPathComponent("sess-alpha-01.jsonl")
        let good = String(decoding: try JSONSerialization.data(withJSONObject: said("user", "good")), as: UTF8.self)
        try Data("{ not json\n\(good)\n{\"type\":\n".utf8).write(to: url)

        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)
        #expect(context.availability == .read)
        #expect(context.messages.map(\.excerpt) == ["good"])
        #expect(context.notes.contains { $0.contains("could not be parsed") })
    }

    // MARK: - Questions, and what we do not claim about them

    @Test("A question's own words and options are shown")
    func questionIsQuotedNotSummarised() throws {
        _ = try write("sess-alpha-01", lines: [
            ["type": "assistant", "sessionId": "sess-alpha-01", "timestamp": "2026-09-06T10:00:00.000Z",
             "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "q1", "name": "AskUserQuestion",
                 "input": ["questions": [["question": "Which schema should the export use?",
                                          "options": [["label": "v2"], ["label": "v3"]]]]]],
             ]]],
        ])
        let question = try #require(SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home).questions.first)
        #expect(question.question == "Which schema should the export use?")
        #expect(question.options == ["v2", "v3"])
    }

    @Test("A question with a matching tool_result is answered")
    func answeredQuestion() throws {
        _ = try write("sess-alpha-01", lines: [
            ["type": "assistant", "sessionId": "sess-alpha-01",
             "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "q1", "name": "AskUserQuestion",
                 "input": ["questions": [["question": "Which schema?", "options": ["v2", "v3"]]]]],
             ]]],
            ["type": "user", "sessionId": "sess-alpha-01",
             "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "q1", "content": "v3"],
             ]]],
        ])
        let question = try #require(SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home).questions.first)
        #expect(question.answered == "answered")
        #expect(question.correlationComplete)
    }

    @Test("A question with an error result is cancelled, never answered")
    func cancelledQuestion() throws {
        // A cancelled, refused or interrupted question came back as a `tool_result` with
        // `is_error`. Counting that as an answer would report a question as dealt with when the
        // person walked away from it.
        _ = try write("sess-alpha-01", lines: [
            ["type": "assistant", "sessionId": "sess-alpha-01",
             "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "q1", "name": "AskUserQuestion",
                 "input": ["questions": [["question": "Which schema?", "options": ["v2"]]]]],
             ]]],
            ["type": "user", "sessionId": "sess-alpha-01",
             "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "q1", "is_error": true,
                 "content": "User cancelled the question"],
             ]]],
        ])
        let question = try #require(SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home).questions.first)
        #expect(question.answered == "cancelled")
        #expect(question.correlationComplete, "we did positively see what came back")
    }

    @Test("A question with no result seen is notObserved — even when the whole file was read")
    func missingResultIsNotObserved() throws {
        _ = try write("sess-alpha-01", lines: [
            ["type": "assistant", "sessionId": "sess-alpha-01",
             "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "q1", "name": "AskUserQuestion",
                 "input": ["questions": [["question": "Which schema?", "options": ["v2"]]]]],
             ]]],
        ])
        // Reading the whole file does not make an absent line into evidence. A transcript is not a
        // record of what a session is waiting for; only a hook can say that, and it is reported
        // separately.
        let question = try #require(SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home).questions.first)
        #expect(question.answered == "notObserved")
        #expect(!question.correlationComplete)
    }

    @Test("A question in a tail we only partly read is notObserved too")
    func partialWindowMeansNotObserved() throws {
        // The answering record may be outside what we read. Calling that "unanswered" would invent
        // a pending request out of a reading limit.
        var lines: [[String: Any]] = (0..<300).map { said("user", "filler \($0) " + String(repeating: "y", count: 300)) }
        lines.append(["type": "assistant", "sessionId": "sess-alpha-01",
                      "message": ["role": "assistant", "content": [
                         ["type": "tool_use", "id": "q1", "name": "AskUserQuestion",
                          "input": ["questions": [["question": "Which schema?", "options": ["v2"]]]]],
                      ]]])
        _ = try write("sess-alpha-01", lines: lines)

        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home, tailBytes: 8192)
        let question = try #require(context.questions.first)
        #expect(context.tailTruncated)
        #expect(question.answered == "notObserved", "a reading limit is not evidence about an answer")
        #expect(!question.correlationComplete)
    }

    @Test("A question mark in ordinary prose is not a question")
    func proseIsNotAQuestion() throws {
        _ = try write("sess-alpha-01", lines: [said("assistant", "Should I use v2 or v3? I went with v3.")])
        #expect(SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home).questions.isEmpty,
                "only a structured AskUserQuestion counts")
    }

    // MARK: - It is context, never evidence

    @Test("Reading a transcript changes no queue, anywhere")
    func readingIsNotAnEvent() throws {
        _ = try write("sess-alpha-01", lines: [
            said("assistant", "Should I continue? Waiting for you."),
            said("user", "yes"),
        ])
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "sess-alpha-01", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        let before = engine.snapshot()

        _ = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)

        #expect(engine.pendingCount == 0, "no card came out of the transcript")
        #expect(engine.snapshot().sessions == before.sessions, "and no state changed")
    }

    @Test("Reading writes nothing to the transcript or its directory")
    func readingWritesNothing() throws {
        let url = try write("sess-alpha-01", lines: [said("user", "hello")])
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let listingBefore = try FileManager.default.contentsOfDirectory(atPath: projects.path).sorted()

        _ = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)

        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(after[.size] as? NSNumber == before[.size] as? NSNumber)
        #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
        #expect(try FileManager.default.contentsOfDirectory(atPath: projects.path).sorted() == listingBefore)
    }

    @Test("Everything it returns can be encoded without leaking what it excluded")
    func encodesCleanly() throws {
        _ = try write("sess-alpha-01", lines: [
            ["type": "assistant", "sessionId": "sess-alpha-01",
             "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "SECRET-THINKING"],
                ["type": "text", "text": "visible"],
             ]]],
        ])
        let context = SessionContextReader.read(sessionID: "sess-alpha-01", claudeHome: home)
        let json = String(decoding: try JSONCoding.encoder.encode(context), as: UTF8.self)
        #expect(json.contains("visible"))
        #expect(!json.contains("SECRET-THINKING"))
    }
}
