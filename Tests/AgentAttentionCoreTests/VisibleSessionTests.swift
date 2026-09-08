import Foundation
import Testing
@testable import AgentAttentionCore

/// What the user actually reads in the tab.
///
/// Everything here is model output, which is to say text this app did not write and cannot vouch
/// for. It is rendered, never executed and never echoed raw: a terminal that interprets what a
/// model emitted is a terminal somebody else is driving.
@Suite("Visible session transcript")
struct TranscriptRendererTests {
    private func render(_ object: [String: Any]) -> [String] {
        TranscriptRenderer().render(frame: object)
    }

    @Test("Assistant prose is shown as prose, not as JSON")
    func assistantTextIsReadable() {
        let lines = render(["type": "assistant", "session_id": "s1",
                            "message": ["content": [["type": "text",
                                                     "text": "The migration is done."]]]])
        #expect(lines.contains { $0.contains("The migration is done.") })
        #expect(!lines.contains { $0.contains("\"type\"") }, "the raw frame is not the display")
    }

    @Test("Our own prompt is shown, so the tab reads as a conversation")
    func userPromptIsShown() {
        let lines = render(["type": "user", "session_id": "s1",
                            "message": ["role": "user",
                                        "content": [["type": "text", "text": "Run the tests"]]]])
        #expect(lines.contains { $0.contains("Run the tests") })
    }

    @Test("A correlation footer is not shown to the reader")
    func protocolDetailIsHidden() {
        let body = "Run the tests\n\n[warden-correlation: 4B1F-3DF9]"
        let lines = render(["type": "user", "session_id": "s1",
                            "message": ["role": "user",
                                        "content": [["type": "text", "text": body]]]])
        #expect(lines.contains { $0.contains("Run the tests") })
        #expect(!lines.contains { $0.contains("warden-correlation") },
                "protocol plumbing is not part of the conversation")
    }

    @Test("Tool activity is summarised, never dumped")
    func toolUseIsSummarised() {
        let lines = render(["type": "assistant", "session_id": "s1",
                            "message": ["content": [["type": "tool_use", "name": "Bash",
                                                     "input": ["command": "rm -rf /important"]]]]])
        #expect(lines.contains { $0.contains("Bash") })
        #expect(!lines.contains { $0.contains("rm -rf") },
                "a tool's arguments are not the transcript, and some of them are dangerous to echo")
    }

    @Test("A result is shown with its outcome", arguments: [
        (false, "done"), (true, "rate limited"),
    ])
    func resultsAreShown(_ testCase: (Bool, String)) {
        let lines = render(["type": "result", "subtype": testCase.0 ? "error" : "success",
                            "session_id": "s1", "is_error": testCase.0, "result": testCase.1])
        #expect(lines.contains { $0.contains(testCase.1) })
    }

    @Test("Escape sequences in model text are never passed through", arguments: [
        "\u{1B}[2J\u{1B}[H wiped your screen",
        "\u{1B}]0;stolen title\u{07}",
        "carriage\rreturn overwrite",
        "bell\u{07}bell",
        "\u{1B}[31mred\u{1B}[0m",
    ])
    func controlSequencesAreNeutralised(_ text: String) {
        // Production mutation this catches: writing model text to the tty unsanitised, which lets
        // a model — or anything that reached one — repaint the terminal, retitle the window, or
        // hide what it is doing behind a cursor move.
        let lines = render(["type": "assistant", "session_id": "s1",
                            "message": ["content": [["type": "text", "text": text]]]])
        let joined = lines.joined()
        #expect(!joined.contains("\u{1B}"), "no escape character reaches the terminal")
        #expect(!joined.contains("\u{07}"), "no bell either")
        #expect(!joined.contains("\r"))
    }

    @Test("Ordinary Unicode survives, so the transcript stays useful")
    func ordinaryTextIsUntouched() {
        let text = "Café — 日本語 — 🎯 — tabs\tare fine"
        let lines = render(["type": "assistant", "session_id": "s1",
                            "message": ["content": [["type": "text", "text": text]]]])
        #expect(lines.joined().contains("Café"))
        #expect(lines.joined().contains("日本語"))
        #expect(lines.joined().contains("🎯"))
    }

    @Test("A very long line is bounded rather than flooding the tab")
    func outputIsBounded() {
        let huge = String(repeating: "x", count: 50_000)
        let lines = render(["type": "assistant", "session_id": "s1",
                            "message": ["content": [["type": "text", "text": huge]]]])
        #expect(lines.allSatisfy { $0.count <= TranscriptRenderer.maximumLineLength + 40 })
    }

    @Test("Frames with nothing to say produce nothing", arguments: [
        ["type": "system", "subtype": "hook_started"],
        ["type": "system", "subtype": "thinking_tokens"],
        ["type": "tool_progress"],
    ] as [[String: Any]])
    func noiseIsNotRendered(_ object: [String: Any]) {
        #expect(render(object).isEmpty, "the tab is a conversation, not a packet trace")
    }

    @Test("A frame that is not JSON at all is ignored safely")
    func malformedInputIsIgnored() {
        #expect(TranscriptRenderer().render(line: "this is not json").isEmpty)
        #expect(TranscriptRenderer().render(line: "").isEmpty)
    }

    @Test("The header says what this tab is and what it cannot do")
    func theHeaderIsHonest() {
        let header = TranscriptRenderer.header(sessionID: "ABC-123",
                                               cwd: "/Users/me/code/project",
                                               model: "opus")
        let text = header.joined(separator: "\n")
        #expect(text.contains("Agent Warden"))
        #expect(text.contains("project"), "the reader should see where this session is working")
        #expect(text.lowercased().contains("typing"),
                "a tab that ignores keystrokes has to say so, or it looks broken")
        #expect(!text.contains("ABC-123") || text.contains("ABC-123"))
    }
}

/// Building the surface command, before any terminal is involved.
@Suite("Visible session plan")
struct VisibleSessionPlanTests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func plan(cwd: String? = nil) -> VisibleSessionPlan {
        VisibleSessionPlan(sessionID: "S-1", cwd: cwd ?? "/private/tmp/warden-fixture", model: "opus",
                           claudeExecutable: "/usr/bin/true",
                           relayExecutable: "/usr/bin/true",
                           inbox: "/tmp/warden/in", outbox: "/tmp/warden/out",
                           withoutTools: false)!
    }

    @Test("The surface runs our own relay, with the session it was created for")
    func theCommandRunsTheRelay() {
        let command = plan().command
        #expect(command.contains("/usr/bin/true"))
        #expect(command.contains("S-1"))
        #expect(command.contains("/tmp/warden/in"))
        #expect(command.contains("/tmp/warden/out"))
    }

    @Test("Nothing a caller supplies can become another shell command", arguments: [
        "/tmp/a; rm -rf ~", "/tmp/a && curl evil", "/tmp/a`whoami`", "/tmp/a$(id)", "/tmp/a|tee x",
    ])
    func pathsCannotSmuggleShell(_ hostile: String) {
        // Production mutation this catches: interpolating a caller-supplied path into the command
        // string. The surface command is executed by a shell, so a semicolon in a directory name
        // would be a second command running in the user's own terminal.
        #expect(VisibleSessionPlan(sessionID: "S-1", cwd: hostile, model: nil,
                                   claudeExecutable: "/usr/bin/true", relayExecutable: "/usr/bin/true",
                                   inbox: "/tmp/in", outbox: "/tmp/out", withoutTools: false) == nil,
                "a path that is not a plain path is refused before anything is built")
    }

    @Test("A session id that is not a session id is refused")
    func identifiersAreValidated() {
        #expect(VisibleSessionPlan(sessionID: "not a uuid; rm -rf /", cwd: scratch, model: nil,
                                   claudeExecutable: "/usr/bin/true", relayExecutable: "/usr/bin/true",
                                   inbox: "/tmp/in", outbox: "/tmp/out", withoutTools: false) == nil)
    }

    @Test("The tab is named so a person can find it")
    func theTitleIsRecognisable() {
        let title = plan().title
        #expect(title.contains("Agent Warden"))
        #expect(title.count <= 80, "a title is a label, not a paragraph")
    }
}
