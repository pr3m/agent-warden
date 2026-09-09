import AppKit
import AgentAttentionCore

/// Talks to Ghostty through its own documented scripting interface, and only in four ways.
///
/// Verified against the installed `Ghostty.sdef` (1.3.1) and the published AppleScript reference:
/// `application → front window → selected tab → focused terminal`, with stable `id` on window, tab
/// and terminal, plus `name` and `working directory`; and the commands `focus`, `exists`,
/// `activate window`, `select tab`. There is **no pid or tty property**, which is exactly why a
/// session cannot be mapped to a tab automatically and why the link is something the user makes.
///
/// What this deliberately does not do, although the dictionary offers it: `input text`, `send key`,
/// `send mouse …`, `new tab`, `new window`, `split`, `close`, `close tab`, `close window`, `quit`.
/// None of them is reachable from anywhere in this app. Agent Warden reads and focuses. It never
/// types into a session, opens one, closes one, or restarts Ghostty.
///
/// Every script here is a fixed string with at most one interpolated value, and that value is
/// validated to Ghostty's own id shape *and* escaped before it goes anywhere near AppleScript.
final class GhosttyAdapter: GhosttyControlling, @unchecked Sendable {
    static let bundleIdentifier = "com.mitchellh.ghostty"
    /// Ghostty answers in milliseconds when it is well; this is the budget before we give up.
    let timeout: TimeInterval

    /// Scheduling lives in `BoundedScriptRunner`, and its gate is **process-wide**: two adapters —
    /// the pairing window's and an activation's — share it, so a second request can never be queued
    /// behind a first one that is still blocked and then fire late.
    private let runner: BoundedScriptRunner
    /// "Is Ghostty running?" — injectable so a check can exercise the scheduling rules without
    /// consulting, or depending on, whatever is really running on the machine.
    private let runningProbe: () -> Bool

    init(timeout: TimeInterval = 5,
         executor: ScriptExecuting? = nil,
         runningProbe: (() -> Bool)? = nil) {
        self.timeout = timeout
        // The app has a main run loop of its own, so the same rule applies here as in the bridge
        // host: an Apple event sent from a background thread while that loop is pumping loses its
        // reply to the main thread and never returns. See `MainRunLoopScriptExecutor`.
        self.runner = BoundedScriptRunner(executor: executor ?? MainRunLoopScriptExecutor(AppleScriptExecutor()))
        self.runningProbe = runningProbe ?? {
            !NSRunningApplication.runningApplications(withBundleIdentifier: GhosttyAdapter.bundleIdentifier).isEmpty
        }
    }

    func frontmostApplicationPID() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    // MARK: - Which Ghostty

    func processIdentity() -> ProcessFingerprint? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: GhosttyAdapter.bundleIdentifier).first else { return nil }
        let pid = app.processIdentifier
        // The kernel's own start time, not the `launchDate` AppKit reports, so this agrees with the
        // same check used for Claude processes elsewhere.
        guard let snapshot = ProcessProbe.snapshot(pid: pid) else { return nil }
        return ProcessFingerprint(pid: pid, startedAt: snapshot.startedAt)
    }

    private var isRunning: Bool { runningProbe() }

    // MARK: - Reading

    /// Every terminal, with the name it is showing. One record per line, four fields each.
    ///
    /// Used only by `TabHandshake`, to find the terminal answering to a token it just wrote. A name
    /// read here is never compared against a session's own name — that would be the guess the
    /// handshake exists to avoid.
    func readAllTerminals() -> Result<[TerminalSnapshot], GhosttyFailure> {
        guard isRunning else { return .failure(.notRunning) }
        // A unit separator between fields and a record separator between terminals: a tab name can
        // contain anything at all, including newlines, and splitting on those would invent tabs.
        let script = """
        tell application id "\(GhosttyAdapter.bundleIdentifier)"
            set fieldSep to (character id 31)
            set recordSep to (character id 30)
            set outText to ""
            repeat with t in terminals
                set outText to outText & (id of t) & fieldSep & (name of t) & fieldSep ¬
                    & (working directory of t) & recordSep
            end repeat
            return outText
        end tell
        """
        switch run(script) {
        case .failure(let failure): return .failure(failure)
        case .success(let text):
            let records = text.components(separatedBy: "\u{1E}")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return .success(records.compactMap { record in
                let fields = record.components(separatedBy: "\u{1F}")
                guard let id = fields.first.map(trimmed), GhosttyAdapter.isPlausibleID(id) else {
                    return nil                      // a record we cannot read is not a terminal
                }
                return TerminalSnapshot(terminalID: id,
                                        name: fields.count > 1 ? fields[1] : nil,
                                        workingDirectory: fields.count > 2 ? trimmed(fields[2]) : nil)
            })
        }
    }

    /// Where every terminal sits: window position, tab position, id, and the title it shows now.
    ///
    /// Walks `windows → tabs → terminals` rather than the flat `terminals` list, because the flat
    /// list has no position in it and the position is half the point — it is the ⌘N number. A tab
    /// holding a split contributes one record per terminal, all sharing that tab's number, which is
    /// correct: both halves of a split are reached by the same key.
    ///
    /// Same separators and the same reasoning as `readAllTerminals`: a tab title is arbitrary user
    /// text and may contain newlines.
    func readTabLayout() -> Result<[TabPlacement], GhosttyFailure> {
        guard isRunning else { return .failure(.notRunning) }
        let script = """
        tell application id "\(GhosttyAdapter.bundleIdentifier)"
            set fieldSep to (character id 31)
            set recordSep to (character id 30)
            set outText to ""
            set windowIndex to 0
            repeat with theWindow in windows
                set windowIndex to windowIndex + 1
                set tabIndex to 0
                repeat with theTab in tabs of theWindow
                    set tabIndex to tabIndex + 1
                    repeat with theTerminal in terminals of theTab
                        set outText to outText & windowIndex & fieldSep & tabIndex & fieldSep ¬
                            & (id of theTerminal) & fieldSep & (name of theTerminal) & recordSep
                    end repeat
                end repeat
            end repeat
            return outText
        end tell
        """
        switch run(script) {
        case .failure(let failure): return .failure(failure)
        case .success(let text):
            // The shape check every id gets before it is stored or scripted, applied here too.
            return .success(TabLayout.parse(text).filter { GhosttyAdapter.isPlausibleID($0.terminalID) })
        }
    }

    func readSelectedTerminal() -> Result<TerminalSnapshot, GhosttyFailure> {
        guard isRunning else { return .failure(.notRunning) }
        // One record per line, in a fixed order. Names and directories can contain anything, so they
        // go last and are only ever displayed.
        let script = """
        tell application id "\(GhosttyAdapter.bundleIdentifier)"
            set theWindow to front window
            set theTab to selected tab of theWindow
            set theTerminal to focused terminal of theTab
            return (id of theTerminal) & linefeed & (id of theTab) & linefeed & (id of theWindow) ¬
                & linefeed & (name of theTerminal) & linefeed & (working directory of theTerminal)
        end tell
        """
        switch run(script) {
        case .failure(let failure):
            // "front window" of an app with no windows is an AppleScript error, not a permission
            // problem. Say which.
            return .failure(failure == .unreadable ? .noSelection : failure)
        case .success(let text):
            let fields = text.components(separatedBy: "\n")
            guard let id = fields.first.map(trimmed), !id.isEmpty else { return .failure(.noSelection) }
            guard GhosttyAdapter.isPlausibleID(id) else { return .failure(.unreadable) }
            return .success(TerminalSnapshot(
                terminalID: id,
                tabID: fields.count > 1 ? trimmed(fields[1]) : nil,
                windowID: fields.count > 2 ? trimmed(fields[2]) : nil,
                name: fields.count > 3 ? String(trimmed(fields[3]).prefix(200)) : nil,
                workingDirectory: fields.count > 4 ? String(trimmed(fields[4]).prefix(400)) : nil
            ))
        }
    }

    func terminalExists(id: String) -> Result<Bool, GhosttyFailure> {
        guard isRunning else { return .failure(.notRunning) }
        guard GhosttyAdapter.isPlausibleID(id) else { return .success(false) }
        let script = """
        tell application id "\(GhosttyAdapter.bundleIdentifier)"
            if exists (terminal id "\(TerminalTarget.appleScriptEscaped(id))") then
                return "yes"
            else
                return "no"
            end if
        end tell
        """
        return run(script).map { trimmed($0) == "yes" }
    }

    func focus(terminalID: String) -> Result<Void, GhosttyFailure> {
        guard isRunning else { return .failure(.notRunning) }
        guard GhosttyAdapter.isPlausibleID(terminalID) else { return .failure(.terminalMissing) }
        let escaped = TerminalTarget.appleScriptEscaped(terminalID)
        // Checked before focusing, so a missing tab is reported as missing rather than as a script
        // error — and so nothing else is ever focused in its place.
        let script = """
        tell application id "\(GhosttyAdapter.bundleIdentifier)"
            if not (exists (terminal id "\(escaped)")) then error "missing"
            focus (terminal id "\(escaped)")
            return "ok"
        end tell
        """
        switch run(script) {
        case .success(let text): return trimmed(text) == "ok" ? .success(()) : .failure(.unreadable)
        case .failure(let failure): return .failure(failure == .unreadable ? .terminalMissing : failure)
        }
    }

    func readFocusedTerminalID() -> Result<String, GhosttyFailure> {
        guard isRunning else { return .failure(.notRunning) }
        let script = """
        tell application id "\(GhosttyAdapter.bundleIdentifier)"
            return id of focused terminal of selected tab of front window
        end tell
        """
        switch run(script) {
        case .failure(let failure): return .failure(failure == .unreadable ? .noSelection : failure)
        case .success(let text):
            let id = trimmed(text)
            return id.isEmpty ? .failure(.noSelection) : .success(id)
        }
    }

    // MARK: - Running one script

    /// Ghostty's ids are opaque strings it issues. This is a shape check, not a parser: anything
    /// that is not a plain identifier never reaches a script, and is never stored as a link.
    static func isPlausibleID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One script at a time, with a deadline the caller can rely on.
    ///
    /// **What a timeout here does and does not mean.** An Apple event already accepted by Ghostty
    /// cannot be recalled: if a `focus` has been delivered, it may still take effect after we have
    /// given up waiting. Pretending otherwise would be the dishonest part. What *is* guaranteed:
    ///
    /// - the gate is **process-wide**, so while any script is outstanding — from any adapter in
    ///   this app — further requests are refused immediately (`.busy`) rather than queued. Clicking
    ///   an unresponsive row repeatedly cannot stack up navigation;
    /// - a request whose deadline passed while it waited to start is **dropped unsent**;
    /// - every script carries `with timeout of N seconds`, so the Apple event itself gives up and
    ///   errors (-1712) instead of leaving the process blocked on a hung terminal;
    /// - a timed-out operation ends its chain. Nothing retries, and the caller reports the timeout
    ///   rather than continuing to a verification step whose answer would be meaningless.
    private func run(_ source: String) -> Result<String, GhosttyFailure> {
        runner.run(GhosttyAdapter.bounded(source, seconds: timeout), timeout: timeout)
    }

    /// Wraps a script in AppleScript's own timeout, so the Apple event has the same budget the
    /// caller does rather than an indefinite one.
    static func bounded(_ source: String, seconds: TimeInterval) -> String {
        let budget = Swift.max(1, Int(seconds.rounded(.up)))
        return """
        with timeout of \(budget) seconds
        \(source)
        end timeout
        """
    }
}


/// The real thing: one `NSAppleScript`, executed where the runner puts it.
///
/// Holds no scheduling policy of its own — that belongs to `BoundedScriptRunner`, so the rules can
/// be tested without AppleScript and so every adapter in the process obeys the same one.
struct AppleScriptExecutor: ScriptExecuting {
    func execute(_ source: String) -> Result<String, GhosttyFailure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.unavailable) }
        var error: NSDictionary?
        let value = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            switch code {
            case -1743, -1744, -10004: return .failure(.permissionDenied)
            case -600, -609: return .failure(.notRunning)
            case -1712: return .failure(.timedOut)
            default: return .failure(.unreadable)
            }
        }
        return .success(value.stringValue ?? "")
    }
}
