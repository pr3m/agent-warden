import AppKit
import AgentAttentionCore

struct ActivationOutcome {
    enum Level: String {
        /// We selected the exact tab and brought its application forward.
        case exactTab
        /// The application is forward, but we could not name the tab.
        case appOnly
        /// Nothing came to the front.
        case failed
    }

    var level: Level
    var message: String
}

/// Executes an `ActivationPlan`.
///
/// Runs entirely off the main thread — AppleScript against a busy terminal can take a second or
/// more, and freezing the alert panel while you wait for it is the opposite of helpful. Results
/// come back on the main queue.
///
/// Everything it reports is what it actually managed. Landing on the right application but the
/// wrong tab is said out loud rather than presented as success, and selecting a tmux pane without
/// raising a window is not called success at all.
///
/// It only ever *activates an application that is already running*. It never launches one: a new
/// terminal window is not the session you were trying to reach, and opening one would leave the
/// real session waiting somewhere you still cannot see. If the terminal is not running, the click
/// refuses and hands you the identifying details instead.
/// Finding and raising the terminal application itself.
///
/// A seam, because `NSRunningApplication.activate()` is not a decision — it is the real window of a
/// real app coming to the front. A self-check that exercises the *decision* must not do that to
/// whatever the user is actually looking at.
protocol TerminalAppControlling {
    /// The already-running instance of this session's terminal, or nil. Never starts anything.
    func isRunning(_ identity: SessionIdentity) -> Bool
    /// Brings it forward. Returns what actually happened, not what was asked for.
    func activate(_ identity: SessionIdentity) -> Bool
}

/// A process-wide brake for self-checks.
///
/// The class of bug it closes: a check that forgets to inject a stand-in and quietly drives the
/// real machine — which is exactly what happened once here, raising the user's own Ghostty from
/// `--uicheck`. Injection is still the mechanism; this makes forgetting it harmless rather than
/// silent. It is set only by `--uicheck`, never in the shipped run.
enum ActivationSafety {
    private static let lock = NSLock()
    private static var forbidden = false

    static var liveActionsForbidden: Bool {
        get { lock.lock(); defer { lock.unlock() }; return forbidden }
        set { lock.lock(); forbidden = newValue; lock.unlock() }
    }

    /// Recorded so a check can assert the brake was never *needed* — a hit means an injection was
    /// missed somewhere, which is a finding in itself.
    private static var recorded: [String] = []
    static var refusals: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func refuse(_ what: String) -> Bool {
        guard liveActionsForbidden else { return false }
        lock.lock(); recorded.append(what); lock.unlock()
        FileHandle.standardError.write(Data("  ! refused a live \(what) during a self-check\n".utf8))
        return true
    }
}

struct SystemTerminalApps: TerminalAppControlling {
    func isRunning(_ identity: SessionIdentity) -> Bool {
        TerminalActivator.runningApplication(for: identity) != nil
    }

    func activate(_ identity: SessionIdentity) -> Bool {
        if ActivationSafety.refuse("application activation") { return false }
        return TerminalActivator.runningApplication(for: identity)?.activate() ?? false
    }
}

/// Answers the decision and touches nothing. Used by `--uicheck`.
final class InertTerminalApps: TerminalAppControlling {
    var running: Bool
    var activates: Bool
    private(set) var activateCalls = 0
    /// Lets a check model what activating an app really means — the window coming forward — without
    /// any window actually doing so.
    var onActivate: (() -> Void)?

    init(running: Bool = true, activates: Bool = true, onActivate: (() -> Void)? = nil) {
        self.running = running
        self.activates = activates
        self.onActivate = onActivate
    }

    func isRunning(_ identity: SessionIdentity) -> Bool { running }

    func activate(_ identity: SessionIdentity) -> Bool {
        activateCalls += 1
        if activates { onActivate?() }
        return activates
    }
}

enum TerminalActivator {

    static func activate(
        _ identity: SessionIdentity,
        pairing: TerminalPairing? = nil,
        ghostty: GhosttyControlling? = nil,
        liveness: LivenessProbing = SystemLiveness(),
        apps: TerminalAppControlling = SystemTerminalApps(),
        completion: @escaping (ActivationOutcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = perform(identity, pairing: pairing, ghostty: ghostty, liveness: liveness, apps: apps)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Synchronous body. Never call this from the main thread.
    static func perform(
        _ identity: SessionIdentity,
        pairing: TerminalPairing? = nil,
        ghostty: GhosttyControlling? = nil,
        liveness: LivenessProbing = SystemLiveness(),
        apps: TerminalAppControlling = SystemTerminalApps()
    ) -> ActivationOutcome {
        // A confirmed link is checked *now*, before it is used. A link that no longer names the same
        // Claude process and the same run of Ghostty is not a weaker link — it points somewhere else.
        var usablePairing: TerminalPairing?
        var pairedAdapter: GhosttyControlling?
        var pinnedGhostty: ProcessFingerprint?
        if let pairing {
            let adapter = ghostty ?? GhosttyAdapter()
            pairedAdapter = adapter

            // The Claude process is **probed now**, not read from the snapshot the caller handed
            // us. A saved record says what was true when the hook fired; a session that has since
            // died, or whose pid has been recycled, would otherwise sail through on stale data.
            guard let pid = identity.claudePID, let recordedStart = identity.claudePIDStartedAt,
                  liveness.probe(pid: pid, startedAt: recordedStart) == .alive else {
                return ActivationOutcome(
                    level: .failed,
                    message: "This session's Claude process is no longer the one that was linked. "
                           + "Open the ⋯ menu → Link Ghostty tab… to link it again."
                )
            }

            let fingerprint = adapter.processIdentity()
            pinnedGhostty = fingerprint
            let exists: Bool? = fingerprint == nil ? nil : (try? adapter.terminalExists(id: pairing.terminalID).get())
            let verdict = PairingValidator.validate(
                pairing: pairing,
                sessionPID: pid,
                sessionPIDStartedAt: recordedStart,
                ghostty: fingerprint,
                terminalExists: exists
            )
            guard verdict.isUsable else {
                return ActivationOutcome(
                    level: .failed,
                    message: verdict.explanation + " Open the ⋯ menu → Link Ghostty tab… to link it again."
                )
            }
            usablePairing = pairing
        }

        let plan = TerminalTarget.plan(for: identity, pairing: usablePairing)
        let isRunning = apps.isRunning(identity)
        let decision = ActivationPolicy.decide(plan: plan,
                                               terminalName: identity.terminalName,
                                               isRunning: isRunning)
        guard case .proceed = decision else {
            return ActivationOutcome(
                level: .failed,
                message: ActivationPolicy.refusalMessage(decision, identity: identity) ?? plan.explanation
            )
        }

        // A linked Ghostty tab is a **transaction**, not a sequence of best efforts. It either
        // lands on the exact tab, with that verified afterwards, or it fails and says why — it
        // never falls through to "well, Ghostty is in front now". Bringing the app forward after a
        // failed focus would leave the user staring at the wrong tab believing they had arrived.
        if let terminalID = plan.steps.compactMap({ step -> String? in
            if case let .ghosttyFocus(id) = step { return id } else { return nil }
        }).first {
            return focusLinkedTab(
                terminalID: terminalID,
                identity: identity,
                adapter: pairedAdapter ?? ghostty ?? GhosttyAdapter(),
                pinned: pinnedGhostty,
                liveness: liveness,
                apps: apps
            )
        }

        var tabSelected = false
        var appRaised = false
        var paneSelected = false
        var problems: [String] = []

        for step in plan.steps {
            switch step {
            case let .tmuxSelect(pane, socket):
                if runTmux(pane: pane, socket: socket) {
                    paneSelected = true
                    tabSelected = true
                } else {
                    problems.append("tmux pane \(pane) could not be selected")
                }

            case let .itermSelect(uuid):
                switch runAppleScript(itermScript(uuid: uuid)) {
                case .success(let value) where value == "ok":
                    tabSelected = true
                    appRaised = true
                case .success:
                    problems.append("iTerm2 session not found (the tab may have closed)")
                case .failure(let message):
                    problems.append(message)
                }

            case let .terminalSelect(tty):
                switch runAppleScript(appleTerminalScript(tty: tty)) {
                case .success(let value) where value == "ok":
                    tabSelected = true
                    appRaised = true
                case .success:
                    problems.append("Terminal tab on \(tty) not found (the tab may have closed)")
                case .failure(let message):
                    problems.append(message)
                }

            case .ghosttyFocus:
                // Handled above as a transaction, and never reached here. Left explicit so adding a
                // step cannot silently reintroduce the app-only fallback this case used to allow.
                problems.append("linked-tab navigation is handled before this point")

            case .activateApp, .activateByName:
                // Activate the instance we already found. Never launch: `NSWorkspace.openApplication`
                // and `open -a` would both start the app if it were not running.
                if isRunning, apps.activate(identity) {
                    appRaised = true
                } else {
                    problems.append("could not bring \(identity.terminalName) forward")
                }
            }
        }

        let detail = problems.joined(separator: "; ")

        if appRaised && tabSelected {
            let how = usablePairing != nil ? " (the tab you linked)" : ""
            return ActivationOutcome(
                level: .exactTab,
                message: "Switched to \(identity.projectName) in \(identity.terminalName)\(how)"
            )
        }
        if appRaised {
            var message = "\(identity.terminalName) is forward — pick the \(identity.projectName) tab"
            let why = detail.isEmpty ? plan.explanation : detail
            if !why.isEmpty { message += ". \(why)" }
            return ActivationOutcome(level: .appOnly, message: message)
        }
        if paneSelected {
            // The pane moved, but nothing came to the front. Saying "switched" here would be a lie.
            return ActivationOutcome(
                level: .failed,
                message: "tmux pane selected, but no terminal window could be brought forward"
            )
        }
        return ActivationOutcome(
            level: .failed,
            message: detail.isEmpty ? "Could not reach the terminal" : detail
        )
    }

    // MARK: - A linked tab, or nothing

    /// Focus the exact linked terminal, prove it landed, and only then say so.
    ///
    /// Every step is fail-closed. A refused, timed-out or misdirected focus returns `.failed`
    /// immediately: no retry, no app raise, no continuation. And because selecting a tab inside
    /// Ghostty does not bring Ghostty forward, "you are looking at it" is proven separately —
    /// after any raise, by re-reading the focused terminal, the frontmost pid and both incarnations.
    /// Anything less would call a link successful on the strength of a request rather than a result.
    private static func focusLinkedTab(
        terminalID: String,
        identity: SessionIdentity,
        adapter: GhosttyControlling,
        pinned: ProcessFingerprint?,
        liveness: LivenessProbing,
        apps: TerminalAppControlling
    ) -> ActivationOutcome {
        // Two different truths, and the wording has to keep them apart. Before the focus request
        // leaves, nothing has happened at all. Once it has been accepted, an Apple event cannot be
        // recalled — the tab may well have changed even though we could not prove it — so saying
        // "nothing was focused" there would be a claim we are not entitled to make.
        func refused(_ why: String) -> ActivationOutcome {
            ActivationOutcome(level: .failed, message: "Nothing was focused — \(why)")
        }
        func unconfirmed(_ why: String) -> ActivationOutcome {
            ActivationOutcome(level: .failed, message: "Could not confirm the linked tab — \(why)")
        }
        func claudeIsAlive() -> Bool {
            guard let pid = identity.claudePID, let started = identity.claudePIDStartedAt else { return true }
            return liveness.probe(pid: pid, startedAt: started) == .alive
        }

        // Between validating and focusing, Ghostty could have restarted. A terminal id means
        // nothing across runs, so it is re-pinned immediately before the request.
        guard let pinned, let before = adapter.processIdentity(), before.matches(pinned) else {
            return refused("Ghostty changed while the link was being checked. "
                           + "Open the ⋯ menu → Link Ghostty tab… to link it again.")
        }

        // And the session is re-probed immediately before the request too, not only after it. The
        // inspection above involves the terminal and can take seconds; a session that ended during
        // it would otherwise have its tab focused on the strength of a stale reading.
        guard claudeIsAlive() else {
            return refused("this session's Claude process ended before its tab could be opened.")
        }

        if case .failure(let failure) = adapter.focus(terminalID: terminalID) {
            // A timeout ends the chain. Verifying afterwards would be asking a question whose
            // answer cannot be attributed to this attempt. A timeout is also the one case where the
            // request may still have been accepted, so it is reported as unconfirmed, not refused.
            return failure == .timedOut ? unconfirmed(failure.explanation) : refused(failure.explanation)
        }

        // Focusing is a request. Reading back what is focused now is the only way to know it was
        // honoured; a command that returned without an error is not evidence of anything.
        switch adapter.readFocusedTerminalID() {
        case .success(let focused) where focused == terminalID:
            break
        case .success(let focused):
            return unconfirmed("Ghostty focused terminal \(focused), not the linked \(terminalID).")
        case .failure(let failure):
            return unconfirmed("the focus could not be read back: \(failure.explanation)")
        }

        // Already in front: nothing to raise. Everything else below still has to hold.
        if adapter.frontmostApplicationPID() != pinned.pid {
            guard apps.isRunning(identity), apps.activate(identity) else {
                return unconfirmed("the linked tab is selected, but \(identity.terminalName) could not be brought forward.")
            }
            // Activating an application is asynchronous, and the selected tab could have moved
            // while the window came forward.
            guard case .success(let focusedNow) = adapter.readFocusedTerminalID(), focusedNow == terminalID else {
                return unconfirmed("the linked tab was no longer selected once Ghostty came forward.")
            }
            guard adapter.frontmostApplicationPID() == pinned.pid else {
                return unconfirmed("the linked tab is selected, but Ghostty is still not the frontmost application.")
            }
        }

        // The last word, on **both** paths — raised or already in front. Another Ghostty could have
        // started at any point during this, and a terminal id means nothing across runs, so the
        // success claim is only made against the incarnation the link was pinned to.
        guard let settled = adapter.processIdentity(), settled.matches(pinned) else {
            return unconfirmed("Ghostty changed while its tab was being opened.")
        }

        // The link is pinned to one Claude process. If that process has gone during the navigation,
        // the tab on screen is no longer this session's tab.
        guard claudeIsAlive() else {
            return unconfirmed("this session's Claude process ended while its tab was being opened.")
        }

        return ActivationOutcome(
            level: .exactTab,
            message: "Switched to \(identity.projectName) in \(identity.terminalName) (the tab you linked)"
        )
    }

    // MARK: - tmux

    private static func runTmux(pane: String, socket: String?) -> Bool {
        if ActivationSafety.refuse("tmux command") { return false }
        // Arguments are passed as an array — never through a shell — and the pane and socket were
        // shape-checked by TerminalTarget before they got here.
        var prefix: [String] = ["tmux"]
        if let socket, !socket.isEmpty { prefix += ["-S", socket] }
        return run("/usr/bin/env", prefix + ["select-window", "-t", pane])
            && run("/usr/bin/env", prefix + ["select-pane", "-t", pane])
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Finding the running application

    /// The already-running instance of this session's terminal, or nil.
    ///
    /// Nothing here can start anything: it only looks through what is already running, by bundle
    /// identifier where we have a bundle path, and by bundle name otherwise.
    static func runningApplication(for identity: SessionIdentity) -> NSRunningApplication? {
        if let path = identity.terminalAppPath, FileManager.default.fileExists(atPath: path),
           let bundleID = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }

        let wanted = identity.terminalName.lowercased()
        guard !wanted.isEmpty, wanted != "terminal" || identity.terminalAppPath != nil else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy == .regular else { return false }
            if let name = app.localizedName?.lowercased(), name == wanted { return true }
            if let bundleName = app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased(),
               bundleName == wanted { return true }
            return false
        }
    }

    // MARK: - AppleScript

    private enum ScriptResult: Sendable {
        case success(String)
        case failure(String)
    }

    /// Sent from the thread that owns the main run loop, for the reason set out on
    /// `MainRunLoopScriptExecutor`: `perform` runs off the main thread by design, and an Apple event
    /// sent from there while the app's run loop is pumping loses its reply to the main thread and
    /// never comes back. The same defect that stalled the bridge host's visible launch lives on this
    /// path too — iTerm2 and Apple Terminal activation — so it is fixed in the same place.
    private static func runAppleScript(_ source: String) -> ScriptResult {
        if ActivationSafety.refuse("terminal AppleScript") { return .failure("refused during a self-check") }
        return MainRunLoopScriptExecutor.onMainRunLoop { sendAppleScript(source) }
            ?? .failure("the main thread did not answer in time")
    }

    private static func sendAppleScript(_ source: String) -> ScriptResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure("could not compile the activation script")
        }
        let output = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 || code == -1744 {
                return .failure("macOS has not granted automation access — allow Agent Warden under System Settings › Privacy & Security › Automation")
            }
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(code)"
            return .failure(message)
        }
        return .success(output.stringValue ?? "")
    }

    // Interpolated values are shape-checked in `TerminalTarget.validated` before a plan is built;
    // escaping here is the second lock on the same door.
    private static func itermScript(uuid: String) -> String {
        """
        on run
          try
            tell application "iTerm2"
              repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                  repeat with theSession in sessions of theTab
                    if (id of theSession) is "\(TerminalTarget.appleScriptEscaped(uuid))" then
                      select theWindow
                      select theTab
                      select theSession
                      activate
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
          on error errText number errNum
            error errText number errNum
          end try
          return "notfound"
        end run
        """
    }

    private static func appleTerminalScript(tty: String) -> String {
        """
        on run
          try
            tell application "Terminal"
              repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                  if (tty of theTab) is "\(TerminalTarget.appleScriptEscaped(tty))" then
                    set selected of theTab to true
                    set index of theWindow to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
          on error errText number errNum
            error errText number errNum
          end try
          return "notfound"
        end run
        """
    }
}
