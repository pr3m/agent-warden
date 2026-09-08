import Foundation

/// Creates Ghostty surfaces through its own scripting API — and only ever ones this app made.
///
/// Ghostty's dictionary offers `new surface configuration` with a `command`, a working directory
/// and environment, then `new tab with configuration` / `new window with configuration`, and hands
/// back stable window, tab and terminal ids. That is what makes this honest: the terminal identity
/// is **read back from Ghostty**, not matched by title or guessed from a working directory, and the
/// command is a property of a surface being created rather than keystrokes sent to one that
/// already exists. Nothing here types into, reuses, or reconfigures a terminal somebody else is
/// using, and no Ghostty setting is changed.
public final class GhosttySurfaceAdapter: GhosttySurfaceCreating, @unchecked Sendable {
    private let runner: BoundedScriptRunner
    private let budget: TimeInterval

    public init(executor: ScriptExecuting? = nil, budget: TimeInterval = 10) {
        self.runner = BoundedScriptRunner(executor: executor ?? SurfaceAppleScriptExecutor())
        self.budget = budget
    }

    public func hasOpenWindow() -> Bool {
        guard case .success(let answer) = run("return (count of windows) as text") else {
            return false
        }
        return (Int(answer.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    public func createSurface(_ plan: VisibleSessionPlan, inNewWindow: Bool)
        -> Result<GhosttySurface, GhosttySurfaceFailure> {
        // Every value below has already been validated as a plain path or identifier by
        // `VisibleSessionPlan`; the quoting here is belt as well as braces.
        // `new tab` needs the window to put the tab **in**. Without it Ghostty answers -1708
        // ("can't continue new tab") — and through `NSAppleScript` that failure does not come back
        // as an error at all: the call simply never returns, so the request sits until its budget
        // runs out. A missing parameter is not something to discover from a timeout, so the target
        // window is always named.
        let creation = inNewWindow
            ? "set theWindow to new window with configuration cfg\nset theTab to selected tab of theWindow"
            : "set theTab to new tab in front window with configuration cfg"
        let source = """
        set cfg to new surface configuration
        set command of cfg to "\(escaped(plan.command))"
        set initial working directory of cfg to "\(escaped(plan.cwd))"
        \(creation)
        set theTerminal to focused terminal of theTab
        return (id of theTerminal) & "\\n" & (id of theTab)
        """
        switch run(source) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let answer):
            let parts = answer.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard parts.count >= 2, GhosttySurfaceAdapter.isPlausibleID(parts[0]) else {
                return .failure(.scriptingFailed)
            }
            // The window id is asked for separately rather than parsed out of a longer answer, so a
            // partial reply cannot become a confident identity.
            let windowID = (try? run("return id of front window").get())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .success(GhosttySurface(windowID: windowID, tabID: parts[1],
                                           terminalID: parts[0]))
        }
    }

    public func surfaceExists(terminalID: String) -> Result<Bool, GhosttySurfaceFailure> {
        guard GhosttySurfaceAdapter.isPlausibleID(terminalID) else { return .success(false) }
        let source = """
        set found to false
        repeat with t in terminals
            if (id of t) is "\(escaped(terminalID))" then set found to true
        end repeat
        return found as text
        """
        return run(source).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "true" }
    }

    public func focus(terminalID: String) -> Result<Void, GhosttySurfaceFailure> {
        guard GhosttySurfaceAdapter.isPlausibleID(terminalID) else { return .failure(.surfaceGone) }
        let source = """
        set target to missing value
        repeat with t in terminals
            if (id of t) is "\(escaped(terminalID))" then set target to t
        end repeat
        if target is missing value then return "gone"
        focus target
        return "focused"
        """
        switch run(source) {
        case .failure(let failure): return .failure(failure)
        case .success(let answer):
            return answer.contains("focused") ? .success(()) : .failure(.surfaceGone)
        }
    }

    /// Closes **one** surface, found by the id this app was given when it created it. A terminal
    /// that is already gone is not an error: the outcome asked for is the outcome that holds.
    public func close(terminalID: String) -> Result<Void, GhosttySurfaceFailure> {
        guard GhosttySurfaceAdapter.isPlausibleID(terminalID) else { return .success(()) }
        let source = """
        set target to missing value
        repeat with t in terminals
            if (id of t) is "\(escaped(terminalID))" then set target to t
        end repeat
        if target is missing value then return "gone"
        close target
        return "closed"
        """
        return run(source).map { _ in () }
    }

    private func run(_ body: String) -> Result<String, GhosttySurfaceFailure> {
        guard FileManager.default.fileExists(atPath: "/Applications/Ghostty.app") else {
            return .failure(.notInstalled)
        }
        let source = """
        with timeout of \(Int(budget)) seconds
            tell application "Ghostty"
                \(body.components(separatedBy: "\n").joined(separator: "\n            "))
            end tell
        end timeout
        """
        switch runner.run(source, timeout: budget) {
        case .success(let answer):
            return .success(answer)
        case .failure(let failure):
            switch failure {
            case .permissionDenied: return .failure(.permissionDenied)
            case .unavailable, .notRunning: return .failure(.notInstalled)
            default: return .failure(.scriptingFailed)
            }
        }
    }

    /// Quotes are the only character AppleScript string literals care about here; everything else
    /// was refused upstream.
    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension GhosttySurfaceAdapter {
    /// A terminal id is a short, printable token. Anything else is not something to put in a
    /// script, and is refused before it gets near one.
    static func isPlausibleID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

/// One `NSAppleScript`, run where the bounded runner puts it. Holds no policy of its own.
struct SurfaceAppleScriptExecutor: ScriptExecuting {
    func execute(_ source: String) -> Result<String, GhosttyFailure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.unavailable) }
        var error: NSDictionary?
        let answer = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743 is the user having refused Automation for this app; it is a decision, not a
            // fault, and it is reported as itself rather than retried.
            if code == -1743 { return .failure(.permissionDenied) }
            if code == -600 || code == -1728 { return .failure(.notRunning) }
            return .failure(.unreadable)
        }
        return .success(answer.stringValue ?? "")
    }
}
