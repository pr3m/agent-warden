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
        self.runner = BoundedScriptRunner(executor: executor ?? GhosttySurfaceAdapter.productionExecutor())
        self.budget = budget
    }

    /// The executor the bridge host and the app really run scripts through.
    ///
    /// Named so the *wiring* can be asserted on its own. The mechanism being right is not the same
    /// as this being the thing that uses it, and the gap between those two was the whole defect: the
    /// script was correct and ran in 0.3s from a probe, while the host — which sent it from a
    /// background queue with its main run loop pumping — never got an answer at all.
    public static func productionExecutor() -> ScriptExecuting {
        MainRunLoopScriptExecutor(SurfaceAppleScriptExecutor())
    }

    /// Is there a window to put a tab in?
    ///
    /// A *failure* here is not the same as "no window", and must not be reported as one: answering
    /// false because the question could not be asked opens a second Ghostty window next to the one
    /// the user already has. The distinction is kept in the return type rather than flattened.
    public func openWindowCount() -> Result<Int, GhosttySurfaceFailure> {
        ScriptTrace.step("hasOpenWindow") {
            run("return (count of windows) as text")
                .flatMap { GhosttySurfaceAdapter.windowCount(from: $0) }
        }
    }

    public func hasOpenWindow() -> Bool {
        GhosttySurfaceAdapter.hasOpenWindow(from: openWindowCount())
    }

    /// Reading the answer, kept apart from asking the question so it can be exercised on its own.
    static func windowCount(from answer: String) -> Result<Int, GhosttySurfaceFailure> {
        guard let count = Int(answer.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            ScriptTrace.note("hasOpenWindow unreadable", answer)
            return .failure(.scriptingFailed)
        }
        ScriptTrace.note("hasOpenWindow count", "\(count)")
        return .success(count)
    }

    /// Only a definite zero means "open a window".
    ///
    /// Anything we could not read leaves the *existing* window as the assumption. Flattening every
    /// error to false was the live defect: one unanswered question and a visible session opened a
    /// second Ghostty window beside the one the user already had. Putting a tab in a window that
    /// turns out not to exist fails loudly and can be retried; an unwanted window cannot be undone.
    static func hasOpenWindow(from count: Result<Int, GhosttySurfaceFailure>) -> Bool {
        guard case .success(let value) = count else { return true }
        return value > 0
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
        let source = GhosttySurfaceAdapter.createSurfaceScript(plan, inNewWindow: inNewWindow)
        ScriptTrace.note("createSurface", "inNewWindow=\(inNewWindow) cwd=\(plan.cwd)")
        switch ScriptTrace.step("createSurface.script", { run(source) }) {
        case .failure(let failure):
            ScriptTrace.note("createSurface failed", "\(failure)")
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

    /// The script that creates a surface, built without sending it.
    ///
    /// Pure on purpose. Its *shape* is the thing worth checking — a missing `in front window` does
    /// not come back as an error, it comes back as a request that never returns — and checking that
    /// through an adapter would drag in the process-wide script gate, which any other caller in the
    /// process may legitimately be holding. A test for what we say to Ghostty should not be able to
    /// fail because of what something else was saying at the time.
    static func createSurfaceScript(_ plan: VisibleSessionPlan, inNewWindow: Bool) -> String {
        // Every value here has already been validated as a plain path or identifier by
        // `VisibleSessionPlan`; the quoting is belt as well as braces.
        let creation = inNewWindow
            ? "set theWindow to new window with configuration cfg\nset theTab to selected tab of theWindow"
            : "set theTab to new tab in front window with configuration cfg"
        return """
        set cfg to new surface configuration
        set command of cfg to "\(escaped(plan.command))"
        set initial working directory of cfg to "\(escaped(plan.cwd))"
        \(creation)
        set theTerminal to focused terminal of theTab
        return (id of theTerminal) & "\\n" & (id of theTab)
        """
    }

    public func surfaceExists(terminalID: String) -> Result<Bool, GhosttySurfaceFailure> {
        guard GhosttySurfaceAdapter.isPlausibleID(terminalID) else { return .success(false) }
        let source = """
        set found to false
        repeat with t in terminals
            if (id of t) is "\(GhosttySurfaceAdapter.escaped(terminalID))" then set found to true
        end repeat
        return found as text
        """
        return run(source).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "true" }
    }

    public func focus(terminalID: String) -> Result<Void, GhosttySurfaceFailure> {
        guard GhosttySurfaceAdapter.isPlausibleID(terminalID) else { return .failure(.surfaceGone) }
        let source = GhosttySurfaceAdapter.actOnMatchedTerminal(
            id: GhosttySurfaceAdapter.escaped(terminalID), verb: "focus", answer: "focused")
        return run(source).flatMap { GhosttySurfaceAdapter.focusOutcome($0) }
    }

    /// What the script's one-word answer means for a focus.
    static func focusOutcome(_ answer: String) -> Result<Void, GhosttySurfaceFailure> {
        switch answer.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "focused": return .success(())
        case "gone": return .failure(.surfaceGone)
        // The match no longer names the same terminal. Refused rather than acted on: a focus that
        // jumps to somebody else's tab is worse than one that did not happen.
        default: return .failure(.scriptingFailed)
        }
    }

    /// Closes **one** surface, found by the id this app was given when it created it. A terminal
    /// that is already gone is not an error: the outcome asked for is the outcome that holds.
    public func close(terminalID: String) -> Result<Void, GhosttySurfaceFailure> {
        guard GhosttySurfaceAdapter.isPlausibleID(terminalID) else { return .success(()) }
        let source = GhosttySurfaceAdapter.actOnMatchedTerminal(
            id: GhosttySurfaceAdapter.escaped(terminalID), verb: "close", answer: "closed")
        switch run(source).flatMap({ GhosttySurfaceAdapter.closeOutcome($0) }) {
        case .failure(let failure):
            return .failure(failure)
        case .success:
            // Ghostty's `close` returns before its own "still has a running process" dialog is
            // answered, so the script saying `closed` is not evidence the tab went away. Ask again.
            // A surface that is still there is a close that did not happen, and reporting it as one
            // that did is how a session ends up looking stopped while its tab is still on screen.
            if case .success(true) = surfaceExists(terminalID: terminalID) {
                ScriptTrace.note("close pending", terminalID)
                return .failure(.scriptingFailed)
            }
            return .success(())
        }
    }

    /// What the script's one-word answer means for a close.
    static func closeOutcome(_ answer: String) -> Result<Void, GhosttySurfaceFailure> {
        switch answer.trimmingCharacters(in: .whitespacesAndNewlines) {
        // A terminal that is already gone is not an error: the outcome asked for is the outcome
        // that holds.
        case "closed", "gone": return .success(())
        // Anything else means the identity check refused. Reported as a failure, because a close
        // that did not happen must never be reported as one that did.
        default: return .failure(.scriptingFailed)
        }
    }

    /// One script for "do `verb` to the terminal with this id, or do nothing at all".
    ///
    /// **The defect this shape exists for.** `repeat with t in terminals` does not bind `t` to a
    /// terminal — it binds a *positional* reference, `item N of every terminal`. `set target to t`
    /// stores that position, so by the time the verb runs, position N can be a different tab: the
    /// script reports success having acted on a terminal this app does not own. Closing somebody
    /// else's tab takes their work with it.
    ///
    /// Two things make that impossible. The reference is dereferenced with `contents of` at the
    /// moment of the match, and the id is **read again immediately before the verb** — so a
    /// reference that has shifted answers `moved` and nothing is touched. A refusal is a far better
    /// outcome than acting on the wrong window, and it is reported as a failure rather than hidden.
    static func actOnMatchedTerminal(id: String, verb: String, answer: String) -> String {
        """
        set wanted to "\(id)"
        set target to missing value
        repeat with t in terminals
            if (id of t) is wanted then set target to (contents of t)
        end repeat
        if target is missing value then return "gone"
        if (id of target) is not wanted then return "moved"
        \(verb) target
        return "\(answer)"
        """
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
        switch ScriptTrace.step("script.run",
                                detail: source.replacingOccurrences(of: "\n", with: " "),
                                { runner.run(source, timeout: budget) }) {
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
    private static func escaped(_ value: String) -> String {
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
