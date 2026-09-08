import Foundation
import Testing
@testable import AgentAttentionCore

/// What the Open button is allowed to promise.
///
/// Ghostty 1.3 has a scripting API that *can* focus a specific terminal — `terminal` has an `id`,
/// and `focus`, `select tab` and `activate window` all exist (checked against the installed
/// `Ghostty.sdef`, 1.3.1). What is missing is the other half: a process has no way to learn which
/// surface it is running in. `terminal` exposes only `id`, `name` and `working directory` — no tty,
/// no pid — and the app exports no surface-id environment variable.
///
/// So exact session targeting is **unmet** on this version, and the honest consequences are:
/// the button says "Open Ghostty", the item stays pending, and we never match on working directory,
/// which would silently pick the wrong tab whenever two sessions share a project.
@Suite("Session targeting promises")
struct SessionTargetingTests {

    private func ghostty(project: String = "alpha", session: String = "sess-1") -> SessionIdentity {
        SessionIdentity(
            sessionID: session,
            cwd: "/Users/dev/code/\(project)",
            claudePID: 4242,
            claudePIDStartedAt: 1,
            tty: "/dev/ttys004",
            termProgram: "ghostty",
            terminalAppPath: "/Applications/Ghostty.app"
        )
    }

    @Test("A Ghostty session's button says Open Ghostty, never Open session")
    func ghosttyButtonLabel() {
        let plan = TerminalTarget.plan(for: ghostty())
        #expect(plan.actionLabel == "Open Ghostty")
        #expect(plan.confidence == .appOnly)
        #expect(plan.confidence != .exactTab, "exact session targeting is not met on this version")
    }

    @Test("The explanation names the real limitation, not a made-up one")
    func ghosttyExplanation() {
        let explanation = TerminalTarget.plan(for: ghostty()).explanation
        #expect(explanation.contains("scripting API"), "Ghostty does have one; do not claim otherwise")
        #expect(explanation.contains("surface id"), "the gap is the session-to-surface link")
        #expect(!explanation.lowercased().contains("no scriptable"))
        #expect(!explanation.lowercased().contains("impossible"))
    }

    @Test("Two sessions in the same project are never distinguished by folder")
    func noCwdMatching() {
        // Matching a terminal by `working directory` is the one mapping Ghostty would allow, and it
        // is exactly wrong here: both of these would match the same tab.
        let first = ghostty(project: "alpha", session: "sess-1")
        let second = ghostty(project: "alpha", session: "sess-2")

        for identity in [first, second] {
            let plan = TerminalTarget.plan(for: identity)
            #expect(plan.confidence == .appOnly)
            #expect(plan.steps.allSatisfy {
                if case .activateApp = $0 { return true } else { return false }
            }, "the only step may be raising the application")
        }
    }

    @Test("Only terminals that can address a tab are offered a session jump")
    func exactTargetingIsEarned() {
        let iterm = SessionIdentity(sessionID: "s", cwd: "/Users/dev/code/alpha",
                                    termProgram: "iTerm.app",
                                    itermSessionID: "w0t0p0:1A2B3C",
                                    terminalAppPath: "/Applications/iTerm.app")
        #expect(TerminalTarget.plan(for: iterm).actionLabel == "Open session tab")

        let terminal = SessionIdentity(sessionID: "s", cwd: "/Users/dev/code/alpha",
                                       tty: "/dev/ttys004", termProgram: "Apple_Terminal",
                                       terminalAppPath: "/System/Applications/Utilities/Terminal.app")
        #expect(TerminalTarget.plan(for: terminal).actionLabel == "Open session tab")
    }

    @Test("With nothing to raise, the button offers the resume command instead")
    func noTargetLabel() {
        let orphan = SessionIdentity(sessionID: "s", cwd: "/Users/dev/code/alpha")
        let plan = TerminalTarget.plan(for: orphan)
        #expect(plan.actionLabel == "Copy resume command")
        #expect(plan.confidence == .none)
    }

    @Test("The identifying help is enough to find the tab by hand")
    func identifyingHelp() {
        let help = TerminalTarget.identifyingHelp(for: ghostty(project: "wunda-api", session: "9f2c-4a1b-full-id"))
        let joined = help.joined(separator: "\n")

        #expect(joined.contains("project: wunda-api"))
        #expect(joined.contains("session: 9f2c-4a1b-full-id"), "the full id, not the abbreviated one")
        #expect(joined.contains("tty: /dev/ttys004"))
        #expect(joined.contains("claude pid: 4242"))
        #expect(joined.contains("claude --resume"))
    }

    @Test("Nothing in a plan ever sends input to a terminal")
    func noInputInjection() {
        // Ghostty's API also exposes `input text` and `send key`. Driving a terminal that way is
        // not something this app does — it watches and points, it does not type.
        for identity in [ghostty(), SessionIdentity(sessionID: "s", cwd: "/x", termProgram: "iTerm.app",
                                                    itermSessionID: "w0t0p0:AB", terminalAppPath: "/Applications/iTerm.app")] {
            for step in TerminalTarget.plan(for: identity).steps {
                switch step {
                case .tmuxSelect, .itermSelect, .terminalSelect, .activateApp, .activateByName,
                     .ghosttyFocus:
                    // Selection, focus and activation only. `input text`, `send key`, `new tab`,
                    // `close` and `quit` are all in Ghostty's dictionary and none of them is here.
                    continue
                }
            }
        }
        #expect(Bool(true))
    }
}

/// Clicking must take you to a session that already exists. It must never make a new one.
@Suite("Activation policy")
struct ActivationPolicyTests {

    private func identity(terminal: String? = "ghostty", appPath: String? = "/Applications/Ghostty.app") -> SessionIdentity {
        SessionIdentity(sessionID: "sess-1", cwd: "/Users/dev/code/alpha",
                        claudePID: 4242, claudePIDStartedAt: 1,
                        termProgram: terminal, terminalAppPath: appPath)
    }

    @Test("A running terminal is activated")
    func runningProceeds() {
        let plan = TerminalTarget.plan(for: identity())
        let decision = ActivationPolicy.decide(plan: plan, terminalName: "Ghostty", isRunning: true)
        #expect(decision == .proceed(plan.steps))
        #expect(ActivationPolicy.refusalMessage(decision, identity: identity()) == nil)
    }

    @Test("A terminal that is not running is refused, never launched")
    func notRunningRefuses() {
        // Opening a fresh window would not take the user to the waiting session; it would take
        // them to an empty one while the real session carries on waiting out of sight.
        let plan = TerminalTarget.plan(for: identity())
        let decision = ActivationPolicy.decide(plan: plan, terminalName: "Ghostty", isRunning: false)
        #expect(decision == .notRunning(appName: "Ghostty"))

        let message = ActivationPolicy.refusalMessage(decision, identity: identity())
        #expect(message?.contains("Ghostty is not running") == true)
        #expect(message?.contains("alpha") == true)
        #expect(message?.contains("Details copied") == true)
    }

    @Test("With nothing recorded there is nothing to activate, running or not", arguments: [true, false])
    func noTargetRefuses(isRunning: Bool) {
        let orphan = SessionIdentity(sessionID: "sess-1", cwd: "/Users/dev/code/alpha")
        let plan = TerminalTarget.plan(for: orphan)
        #expect(plan.steps.isEmpty)
        let decision = ActivationPolicy.decide(plan: plan, terminalName: "terminal", isRunning: isRunning)
        #expect(decision == .noTarget)
        #expect(ActivationPolicy.refusalMessage(decision, identity: orphan)?.contains("No terminal was recorded") == true)
    }

    @Test("Every step a plan can contain is a selection or an activation, never a launch")
    func stepsNeverCreate() {
        // The vocabulary itself is the guarantee: there is no "open a new window" step to reach for.
        for identity in [identity(),
                         identity(terminal: "iTerm.app", appPath: "/Applications/iTerm.app"),
                         identity(terminal: "Apple_Terminal", appPath: "/System/Applications/Utilities/Terminal.app")] {
            for step in TerminalTarget.plan(for: identity).steps {
                switch step {
                case .tmuxSelect, .itermSelect, .terminalSelect, .activateApp, .activateByName,
                     .ghosttyFocus:
                    continue
                }
            }
        }
        #expect(Bool(true))
    }

    @Test("A refusal is a failure, so the caller leaves the item pending")
    func refusalIsNotSuccess() {
        // `.proceed` is the only decision that can lead to an item being cleared; both refusals
        // carry a message and no steps to run.
        for decision in [ActivationDecision.notRunning(appName: "Ghostty"), .noTarget] {
            if case .proceed = decision { Issue.record("a refusal must not proceed") }
            #expect(ActivationPolicy.refusalMessage(decision, identity: identity()) != nil)
        }
    }
}
