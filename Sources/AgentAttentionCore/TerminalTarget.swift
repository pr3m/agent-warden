import Foundation

/// One concrete action taken when the user clicks an alert card.
public enum ActivationStep: Equatable, Sendable {
    /// Switch the tmux client to the recorded pane before touching the GUI.
    case tmuxSelect(pane: String, socket: String?)
    /// iTerm2 exposes a stable per-session id, so the exact tab can be selected.
    case itermSelect(sessionUUID: String)
    /// Apple Terminal exposes each tab's tty, so the exact tab can be selected.
    case terminalSelect(tty: String)
    /// Bring an application forward by its bundle path.
    case activateApp(bundlePath: String)
    /// Bring an application forward by name when we never resolved a bundle path.
    case activateByName(String)
    /// Focus one exact Ghostty terminal by its own id, through Ghostty's scripting interface.
    /// Only ever produced from a link the user confirmed.
    case ghosttyFocus(terminalID: String)
}

/// How much we can honestly promise before we try.
public enum ActivationConfidence: String, Equatable, Sendable {
    /// We can name the exact tab *and* bring its application forward.
    case exactTab
    /// We can only bring the terminal application forward.
    case appOnly
    /// We cannot raise anything. Clicking offers the resume command instead.
    case none

    /// What the card says before you click. `.none` must not read like `.appOnly`.
    public var cardLabel: String {
        switch self {
        case .exactTab: return "click → exact tab"
        case .appOnly: return "click → app only"
        case .none: return "click → copy resume command"
        }
    }
}

public struct ActivationPlan: Equatable, Sendable {
    public var steps: [ActivationStep]
    public var confidence: ActivationConfidence
    /// Shown to the user *before* clicking, so the fallback is never a surprise.
    public var explanation: String
    /// What the button says. Never "Open session" unless we can actually land on that session —
    /// "Open Ghostty" promises what it delivers.
    public var actionLabel: String

    public init(steps: [ActivationStep], confidence: ActivationConfidence, explanation: String, actionLabel: String) {
        self.steps = steps
        self.confidence = confidence
        self.explanation = explanation
        self.actionLabel = actionLabel
    }
}

/// Works out how to get the human back to the session that is asking for them.
///
/// Two disciplines here:
///
/// - **Only promise what we can actually deliver.** Ghostty 1.3 has a scripting API that can focus
///   a specific terminal, but a session has no way to learn which surface it occupies, so the link
///   from session to tab cannot be made and the card says "app only". Selecting a tmux pane without
///   also being able to raise a window is not an exact-tab outcome either — the pane changes behind
///   a window you still have to find.
/// - **Validate every value before it can reach AppleScript or a shell.** These strings come from
///   the environment of whatever launched Claude Code. Anything that does not match the shape the
///   terminal actually emits is dropped, not escaped and hoped for.
public enum TerminalTarget {
    /// `pairing` is a link the user confirmed and that has just been validated. It is the only way
    /// a Ghostty session becomes exact-tab: nothing here derives a terminal id from a tty, a title
    /// or a working directory.
    public static func plan(for identity: SessionIdentity, pairing: TerminalPairing? = nil) -> ActivationPlan {
        if let pairing, normalizedTermProgram(identity) == "ghostty" || identity.terminalAppPath?.lowercased().contains("ghostty") == true {
            var steps: [ActivationStep] = [.ghosttyFocus(terminalID: pairing.terminalID)]
            if let path = identity.terminalAppPath.flatMap({ validated($0, as: .appBundlePath) }) {
                steps.append(.activateApp(bundlePath: path))
            }
            let tab = pairing.terminalName.map { " (\($0))" } ?? ""
            return ActivationPlan(
                steps: steps,
                confidence: .exactTab,
                explanation: "Focusing the Ghostty tab you linked to this session\(tab), by its own terminal id "
                           + "\(pairing.terminalID). The link is checked against this Ghostty and this Claude "
                           + "process before anything is focused, and the result is read back afterwards.",
                actionLabel: "Open linked tab"
            )
        }

        var tabSteps: [ActivationStep] = []
        var appStep: ActivationStep?
        var notes: [String] = []

        if let rawPane = identity.tmuxPane, !rawPane.isEmpty {
            if let pane = validated(rawPane, as: .tmuxPane) {
                let socket = identity.tmuxSocket.flatMap { validated($0, as: .path) }
                tabSteps.append(.tmuxSelect(pane: pane, socket: socket))
                notes.append("selecting tmux pane \(pane)")
            } else {
                notes.append("tmux pane id has an unexpected shape and was ignored")
            }
        }

        switch normalizedTermProgram(identity) {
        case "iterm":
            if let uuid = itermSessionUUID(identity.itermSessionID) {
                tabSteps.append(.itermSelect(sessionUUID: uuid))
                notes.append("selecting the iTerm2 session by id")
            } else {
                notes.append("iTerm2 session id missing or malformed — bringing iTerm2 forward only")
            }
        case "apple_terminal":
            if let tty = identity.tty.flatMap({ validated($0, as: .tty) }) {
                tabSteps.append(.terminalSelect(tty: tty))
                notes.append("selecting the Terminal tab on \(tty)")
            } else {
                notes.append("no usable tty recorded — bringing Terminal forward only")
            }
        case "ghostty":
            // Ghostty 1.3+ *does* have a scripting API: `terminal` has an `id`, and `focus`,
            // `select tab` and `activate window` all exist (verified against the installed
            // Ghostty.sdef, 1.3.1). What is missing is the other half of the link — a running
            // process has no way to learn which surface it is in. `terminal` exposes only id, name
            // and working directory; no tty, no pid; and the app exports no surface-id environment
            // variable. Matching on working directory would pick the wrong tab whenever two
            // sessions share a project, so we do not guess.
            notes.append("Ghostty 1.3.1 has a scripting API, but a session cannot learn its own surface id, so the exact tab cannot be addressed — bringing Ghostty forward; pick the \(identity.projectName) tab")
        case let other where !other.isEmpty:
            notes.append("\(identity.terminalName) has no verified tab targeting — bringing it forward")
        default:
            notes.append("terminal not identified")
        }

        if let path = identity.terminalAppPath.flatMap({ validated($0, as: .appBundlePath) }) {
            appStep = .activateApp(bundlePath: path)
        } else if let name = validated(identity.terminalName, as: .appName), name != "terminal" {
            appStep = .activateByName(name)
        }

        let steps = tabSteps + (appStep.map { [$0] } ?? [])
        guard !steps.isEmpty else {
            return ActivationPlan(
                steps: [],
                confidence: .none,
                explanation: "No terminal recorded for this session — the resume command is the way back.",
                actionLabel: "Copy resume command"
            )
        }

        let confidence: ActivationConfidence
        if appStep == nil {
            // We can move the pane, but nothing will come to the front. Do not sell that as a
            // successful jump.
            confidence = .none
            notes.append("no terminal application to bring forward")
        } else {
            confidence = tabSteps.isEmpty ? .appOnly : .exactTab
        }

        return ActivationPlan(
            steps: steps,
            confidence: confidence,
            explanation: notes.joined(separator: "; "),
            actionLabel: actionLabel(confidence: confidence, identity: identity)
        )
    }

    /// The button label. It states the outcome we can actually deliver.
    static func actionLabel(confidence: ActivationConfidence, identity: SessionIdentity) -> String {
        switch confidence {
        case .exactTab:
            return "Open session tab"
        case .appOnly:
            return "Open \(identity.terminalName)"
        case .none:
            return "Copy resume command"
        }
    }

    /// What to show — or copy — when we can only raise the application and the human has to find
    /// the tab. Everything here identifies the session without guessing at anything.
    public static func identifyingHelp(for identity: SessionIdentity) -> [String] {
        var lines = [
            "project: \(identity.projectName)",
            "folder: \(identity.cwd)",
            "session: \(identity.sessionID)",
        ]
        if let tty = identity.tty, !tty.isEmpty { lines.append("tty: \(tty)") }
        if let pid = identity.claudePID { lines.append("claude pid: \(pid)") }
        lines.append("resume: \(resumeCommand(for: identity))")
        return lines
    }

    public static func normalizedTermProgram(_ identity: SessionIdentity) -> String {
        if let program = identity.termProgram?.lowercased(), !program.isEmpty {
            if program.contains("iterm") { return "iterm" }
            if program.contains("apple_terminal") { return "apple_terminal" }
            if program.contains("ghostty") { return "ghostty" }
            return program
        }
        if let path = identity.terminalAppPath?.lowercased() {
            if path.contains("iterm") { return "iterm" }
            if path.contains("/terminal.app") { return "apple_terminal" }
            if path.contains("ghostty") { return "ghostty" }
        }
        return ""
    }

    /// iTerm2 exports `ITERM_SESSION_ID` as "w0t0p0:UUID"; AppleScript matches on the UUID.
    public static func itermSessionUUID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let candidate = raw.contains(":") ? String(raw.split(separator: ":").last!) : raw
        return validated(candidate, as: .itermSessionUUID)
    }

    /// Always-available fallback the user can paste anywhere.
    public static func resumeCommand(for identity: SessionIdentity) -> String {
        "cd \(shellQuoted(identity.cwd)) && claude --resume \(shellQuoted(identity.sessionID))"
    }

    // MARK: - Validation

    enum Shape {
        case itermSessionUUID
        case tty
        case tmuxPane
        case path
        case appBundlePath
        case appName
    }

    /// Returns the value only if it matches the shape the terminal actually emits.
    static func validated(_ value: String, as shape: Shape) -> String? {
        guard !value.isEmpty, value.count <= 512 else { return nil }
        guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }

        func matches(_ pattern: String) -> Bool {
            value.range(of: pattern, options: [.regularExpression]) == value.startIndex..<value.endIndex
        }

        switch shape {
        case .itermSessionUUID:
            return matches("[A-Za-z0-9-]{1,64}") ? value : nil
        case .tty:
            return matches("/dev/tty[A-Za-z0-9]{1,16}") ? value : nil
        case .tmuxPane:
            return matches("%?[A-Za-z0-9_.:@-]{1,64}") ? value : nil
        case .path:
            return matches("/[A-Za-z0-9_./@%+-]{1,255}") ? value : nil
        case .appBundlePath:
            return matches("/[A-Za-z0-9 _./+-]{1,500}\\.app") ? value : nil
        case .appName:
            return matches("[A-Za-z0-9 ._-]{1,64}") ? value : nil
        }
    }

    /// Backstop for anything interpolated into AppleScript source. Values are validated first;
    /// this is the second lock on the same door.
    public static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Single-quote for a POSIX shell, the way `shlex.quote` does.
    public static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Whether a click may do anything at all.
public enum ActivationDecision: Equatable, Sendable {
    case proceed([ActivationStep])
    /// The terminal this session lives in is not running. We do not start it.
    case notRunning(appName: String)
    /// Nothing was ever recorded to aim at.
    case noTarget
}

/// The rule that clicking an alert never *creates* anything.
///
/// Opening a fresh terminal window would not take you to the waiting session — it would take you
/// to a new, empty one, while the session carries on waiting somewhere you still cannot see. If the
/// application is not running, the session cannot be in it, and the honest answer is the
/// identifying details rather than a new window.
///
/// Split out from the AppKit code so the decision itself is testable.
public enum ActivationPolicy {
    public static func decide(plan: ActivationPlan, terminalName: String, isRunning: Bool) -> ActivationDecision {
        guard !plan.steps.isEmpty else { return .noTarget }
        guard isRunning else { return .notRunning(appName: terminalName) }
        return .proceed(plan.steps)
    }

    /// What to tell the user when we refuse.
    public static func refusalMessage(_ decision: ActivationDecision, identity: SessionIdentity) -> String? {
        switch decision {
        case .proceed:
            return nil
        case .notRunning(let appName):
            return "\(appName) is not running, so \(identity.projectName) cannot be in it. "
                 + "Details copied — the session may have ended, or its terminal was quit."
        case .noTarget:
            return "No terminal was recorded for \(identity.projectName) — details copied instead."
        }
    }
}
