import Foundation
import Testing
@testable import AgentAttentionCore

/// What we promise before the user clicks, and what we refuse to pass to AppleScript or a shell.
@Suite("Click-through targeting")
struct TerminalTargetTests {

    @Test("iTerm2 gets exact tab targeting")
    func itermExactTab() {
        let identity = Fixture.identity(
            session: "s1",
            termProgram: "iTerm.app",
            itermSessionID: "w0t1p0:9C6D1F5A-1111-2222-3333-444455556666",
            terminalAppPath: "/Applications/iTerm.app"
        )
        let plan = TerminalTarget.plan(for: identity)
        #expect(plan.confidence == .exactTab)
        #expect(plan.steps.contains(.itermSelect(sessionUUID: "9C6D1F5A-1111-2222-3333-444455556666")))
        #expect(plan.steps.contains(.activateApp(bundlePath: "/Applications/iTerm.app")))
    }

    @Test("iTerm2 without a session id falls back to the app")
    func itermWithoutSessionID() {
        let identity = Fixture.identity(session: "s1", termProgram: "iTerm.app", itermSessionID: nil, terminalAppPath: "/Applications/iTerm.app")
        let plan = TerminalTarget.plan(for: identity)
        #expect(plan.confidence == .appOnly)
        #expect(plan.explanation.contains("session id missing"))
    }

    @Test("Apple Terminal targets the tab by tty")
    func appleTerminalByTty() {
        let identity = Fixture.identity(
            session: "s1",
            termProgram: "Apple_Terminal",
            tty: "/dev/ttys004",
            terminalAppPath: "/System/Applications/Utilities/Terminal.app"
        )
        let plan = TerminalTarget.plan(for: identity)
        #expect(plan.confidence == .exactTab)
        #expect(plan.steps.contains(.terminalSelect(tty: "/dev/ttys004")))
    }

    @Test("Apple Terminal without a tty is honest about it")
    func appleTerminalWithoutTty() {
        let identity = Fixture.identity(session: "s1", termProgram: "Apple_Terminal", tty: nil, terminalAppPath: "/System/Applications/Utilities/Terminal.app")
        let plan = TerminalTarget.plan(for: identity)
        #expect(plan.confidence == .appOnly)
        #expect(plan.explanation.contains("no usable tty"))
    }

    @Test("Ghostty is honest about having no tab handle")
    func ghosttyIsHonest() {
        let identity = Fixture.identity(session: "s1", project: "alpha", termProgram: "ghostty", terminalAppPath: "/Applications/Ghostty.app")
        let plan = TerminalTarget.plan(for: identity)
        #expect(plan.confidence == .appOnly)
        #expect(plan.explanation.contains("Ghostty"))
        #expect(plan.explanation.contains("alpha"), "the fallback should say which tab to look for")
        #expect(plan.steps == [.activateApp(bundlePath: "/Applications/Ghostty.app")])
    }

    @Test("A tmux pane is selected before the terminal is raised")
    func tmuxFirst() {
        let identity = Fixture.identity(session: "s1", termProgram: "ghostty", terminalAppPath: "/Applications/Ghostty.app", tmuxPane: "%7")
        let plan = TerminalTarget.plan(for: identity)
        #expect(plan.confidence == .exactTab)
        #expect(plan.steps.first == .tmuxSelect(pane: "%7", socket: nil))
    }

    @Test("Selecting a tmux pane with no window to raise is not an exact-tab promise")
    func tmuxWithoutATerminalIsNotSuccess() {
        // The pane moves, but nothing comes to the front — the user is still hunting for a window.
        let identity = SessionIdentity(sessionID: "s1", cwd: "/Users/dev/code/alpha", tmuxPane: "%7")
        let plan = TerminalTarget.plan(for: identity)
        #expect(plan.confidence == .none)
        #expect(plan.explanation.contains("no terminal application to bring forward"))
    }

    @Test("Nothing recorded means no promise at all")
    func nothingRecorded() {
        let plan = TerminalTarget.plan(for: SessionIdentity(sessionID: "s1", cwd: "/Users/dev/code/alpha"))
        #expect(plan.confidence == .none)
        #expect(plan.steps.isEmpty)
        #expect(plan.explanation.contains("resume command"))
    }

    @Test("An unknown terminal still gets brought forward")
    func unknownTerminal() {
        let identity = Fixture.identity(session: "s1", termProgram: "WezTerm", terminalAppPath: "/Applications/WezTerm.app")
        let plan = TerminalTarget.plan(for: identity)
        #expect(plan.confidence == .appOnly)
        #expect(plan.explanation.contains("no verified tab targeting"))
    }

    @Test("Each confidence level reads differently on the card")
    func cardLabelsAreDistinct() {
        let labels = Set(ActivationConfidence.allLabels)
        #expect(labels.count == 3, "\"app only\" and \"no target\" must not read the same")
        #expect(ActivationConfidence.none.cardLabel.contains("resume"))
        #expect(ActivationConfidence.appOnly.cardLabel.contains("app only"))
        #expect(ActivationConfidence.exactTab.cardLabel.contains("exact tab"))
    }

    // MARK: - Validation of anything that reaches AppleScript or a shell

    @Test("A malformed iTerm session id is dropped, not escaped and hoped for", arguments: [
        "w0t0p0:\" & (do shell script \"whoami\") & \"",
        "w0t0p0:abc\ndef",
        "w0t0p0:../../etc",
        "w0t0p0:'; rm -rf /; '",
    ])
    func hostileItermSessionID(raw: String) {
        #expect(TerminalTarget.itermSessionUUID(raw) == nil)
        let identity = Fixture.identity(session: "s1", termProgram: "iTerm.app", itermSessionID: raw, terminalAppPath: "/Applications/iTerm.app")
        let plan = TerminalTarget.plan(for: identity)
        #expect(!plan.steps.contains { if case .itermSelect = $0 { return true } else { return false } })
        #expect(plan.confidence == .appOnly)
    }

    @Test("A malformed tty is dropped", arguments: [
        "/dev/ttys004\" & beep & \"", "/etc/passwd", "ttys004", "/dev/ttys004; whoami",
    ])
    func hostileTty(raw: String) {
        let identity = Fixture.identity(session: "s1", termProgram: "Apple_Terminal", tty: raw,
                                        terminalAppPath: "/System/Applications/Utilities/Terminal.app")
        let plan = TerminalTarget.plan(for: identity)
        #expect(!plan.steps.contains { if case .terminalSelect = $0 { return true } else { return false } })
        #expect(plan.confidence == .appOnly)
    }

    @Test("A malformed tmux pane is dropped", arguments: [
        "%7; rm -rf /", "$(whoami)", "%7\nkill-server", "`id`",
    ])
    func hostileTmuxPane(raw: String) {
        let identity = Fixture.identity(session: "s1", termProgram: "ghostty",
                                        terminalAppPath: "/Applications/Ghostty.app", tmuxPane: raw)
        let plan = TerminalTarget.plan(for: identity)
        #expect(!plan.steps.contains { if case .tmuxSelect = $0 { return true } else { return false } })
        #expect(plan.explanation.contains("unexpected shape"))
    }

    @Test("A terminal path that is not an app bundle is not launched")
    func hostileAppPath() {
        for raw in ["/bin/sh", "/Applications/Evil.app\n/bin/sh", "relative/Thing.app"] {
            let identity = Fixture.identity(session: "s1", termProgram: "ghostty", terminalAppPath: raw)
            let plan = TerminalTarget.plan(for: identity)
            #expect(!plan.steps.contains { if case .activateApp = $0 { return true } else { return false } },
                    "should not try to open \(raw)")
        }
    }

    @Test("Escaping is applied on top of validation")
    func escaping() {
        #expect(TerminalTarget.appleScriptEscaped("a\"b") == "a\\\"b")
        #expect(TerminalTarget.appleScriptEscaped("a\\b") == "a\\\\b")
        #expect(TerminalTarget.shellQuoted("/Users/dev/My Code") == "'/Users/dev/My Code'")
        #expect(TerminalTarget.shellQuoted("plain/path-1.2") == "plain/path-1.2")
        #expect(TerminalTarget.shellQuoted("it's") == #"'it'\''s'"#)
        #expect(TerminalTarget.shellQuoted("") == "''")
    }

    @Test("The resume command is safe to paste even for hostile paths")
    func resumeCommandQuoting() {
        let identity = SessionIdentity(sessionID: "sess-1", cwd: "/Users/dev/My Code/alpha")
        #expect(TerminalTarget.resumeCommand(for: identity) == "cd '/Users/dev/My Code/alpha' && claude --resume sess-1")

        let nasty = SessionIdentity(sessionID: "s; rm -rf /", cwd: "/tmp/$(whoami)")
        let command = TerminalTarget.resumeCommand(for: nasty)
        #expect(command.contains("'/tmp/$(whoami)'"))
        #expect(command.contains("'s; rm -rf /'"))
    }

    @Test("iTerm session id parsing")
    func itermSessionIDParsing() {
        #expect(TerminalTarget.itermSessionUUID("w0t1p0:ABC") == "ABC")
        #expect(TerminalTarget.itermSessionUUID("ABC") == "ABC")
        #expect(TerminalTarget.itermSessionUUID(nil) == nil)
        #expect(TerminalTarget.itermSessionUUID("") == nil)
    }

    @Test("Display names come from the bundle path, then the environment")
    func displayNames() {
        #expect(Fixture.identity(session: "s1", termProgram: nil, terminalAppPath: "/Applications/Ghostty.app").terminalName == "Ghostty")
        #expect(Fixture.identity(session: "s1", termProgram: "Apple_Terminal", terminalAppPath: nil).terminalName == "Terminal")
        #expect(Fixture.identity(session: "s1", termProgram: nil, terminalAppPath: nil).terminalName == "terminal")
        #expect(Fixture.identity(session: "s1", project: "wunda-632").projectName == "wunda-632")
        #expect(SessionIdentity(sessionID: "s", cwd: "").projectName == "unknown")
        #expect(SessionIdentity(sessionID: "abcdef0123456789", cwd: "/x").shortSessionID == "abcdef01")
    }
}

extension ActivationConfidence {
    static var allLabels: [String] {
        [ActivationConfidence.exactTab, .appOnly, .none].map(\.cardLabel)
    }
}
