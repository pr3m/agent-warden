import AppKit
import AgentAttentionCore

/// "Link Ghostty tab…" — the user tells Agent Warden which tab a session lives in.
///
/// This window exists because the mapping cannot be discovered. Ghostty 1.3.1 gives a terminal an
/// id, a name and a working directory, but no pid and no tty, so nothing in the running system can
/// prove which tab a Claude session is in. Matching on directory or title would be a guess, and a
/// guess sends somebody to a stranger's tab with full confidence. So the person who knows tells us,
/// once, per session — and **that confirmation is the evidence**, recorded as such.
///
/// The shape of the interaction is deliberate:
///
/// 1. You select the tab in Ghostty yourself. Agent Warden never opens, closes or restarts it.
/// 2. **Read selected tab** asks Ghostty what is focused and shows it back to you, beside the
///    session it would be linked to.
/// 3. **Confirm link** re-reads before saving. If the selected tab, the Ghostty process or the
///    session has changed in between, the preview is replaced and nothing is written — a silent
///    switch here would link the wrong tab.
final class PairingWindow: NSObject, NSWindowDelegate {
    /// What a confirmation produced. **Returns whether it was actually persisted** — a link the
    /// caller failed to write is not a link, and the window must not say otherwise.
    var onConfirm: ((TerminalPairing) -> Bool)?
    var onUnlink: ((String) -> Bool)?
    /// The session as the engine knows it **right now**.
    ///
    /// The window opens with a snapshot, and Automation can take seconds. In that time the session
    /// can end and a new one can be started in the same place — Claude Code reuses a session id on
    /// resume, so the id matching is not enough. Comparing the live record's process identity is
    /// what stops a link being pinned to a Claude that no longer exists.
    var currentIdentity: ((String) -> SessionIdentity?)?

    private var window: NSWindow?
    private let sessionLabel = NSTextField(labelWithString: "")
    private let sessionDetail = NSTextField(labelWithString: "")
    private let existingLabel = NSTextField(labelWithString: "")
    private let instructions = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var readButton: ClosureButton?
    private var confirmButton: ClosureButton?
    private var unlinkButton: ClosureButton?

    private var identity: SessionIdentity?
    private var existing: TerminalPairing?
    private var preview: TerminalSnapshot?
    private var previewFingerprint: ProcessFingerprint?
    /// Bumped whenever the window is shown, closed, or starts a new operation. A callback carrying
    /// an old generation is a result for a question nobody is asking any more, and is dropped —
    /// checking the session id alone would miss the same session being re-opened.
    private var generation = 0
    private var busy = false
    private let liveness: LivenessProbing

    private let ghostty: GhosttyControlling
    private let queue = DispatchQueue(label: "ai.wundamental.agent-warden.pairing", qos: .userInitiated)
    /// Where the two halves of an ask run. AppleScript can take a moment and must not block the
    /// main queue; `--uicheck` swaps both for immediate ones so the same code can be driven without
    /// a run loop.
    private let runOffMain: (@escaping () -> Void) -> Void
    private let runOnMain: (@escaping () -> Void) -> Void

    init(
        ghostty: GhosttyControlling = GhosttyAdapter(),
        liveness: LivenessProbing = SystemLiveness(),
        runOffMain: ((@escaping () -> Void) -> Void)? = nil,
        runOnMain: ((@escaping () -> Void) -> Void)? = nil
    ) {
        self.ghostty = ghostty
        self.liveness = liveness
        let queue = DispatchQueue(label: "ai.wundamental.agent-warden.pairing", qos: .userInitiated)
        self.runOffMain = runOffMain ?? { work in queue.async(execute: work) }
        self.runOnMain = runOnMain ?? { work in DispatchQueue.main.async(execute: work) }
        super.init()
    }

    /// The red button is a close too. Without this, a read or a confirm still in flight would come
    /// back to a window the user has already dismissed — and could save a link they walked away
    /// from. `close()` is the app's own path; this is the one macOS drives.
    func windowWillClose(_ notification: Notification) {
        generation += 1
        busy = false
    }

    /// Drives the same logic without a run loop. Used only by `--uicheck`.
    static func synchronous(ghostty: GhosttyControlling,
                            liveness: LivenessProbing = StubLiveness()) -> PairingWindow {
        PairingWindow(ghostty: ghostty, liveness: liveness, runOffMain: { $0() }, runOnMain: { $0() })
    }

    // MARK: - Presentation

    func show(identity: SessionIdentity, existing: TerminalPairing?) {
        // Reopening — even for the same session — invalidates anything still in flight.
        generation += 1
        busy = false
        self.identity = identity
        self.existing = existing
        self.preview = nil
        self.previewFingerprint = nil
        build()

        sessionLabel.stringValue = identity.displayName
        sessionDetail.stringValue = PairingWindow.sessionDetail(identity)
        existingLabel.stringValue = PairingWindow.existingLine(existing)
        instructions.stringValue = PairingWindow.instructions
        previewLabel.stringValue = "Nothing read yet."
        statusLabel.stringValue = ""
        confirmButton?.isEnabled = false
        unlinkButton?.isEnabled = existing != nil

        window?.title = "Link Ghostty tab — \(identity.displayName)"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        // A read or confirm that comes back after this must not save anything.
        generation += 1
        busy = false
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Copy, kept out of the layout so it can be checked

    static let instructions = """
    1. In Ghostty, click the tab this session is running in. Agent Warden will not open, close or \
    switch anything for you.
    2. Come back here and press Read selected tab.
    3. Check that the tab shown below is the right one, then press Confirm link.

    macOS may ask once for permission to control Ghostty. Agent Warden only reads which tab is \
    selected and focuses the one you link — it never types into a session.
    """

    static func sessionDetail(_ identity: SessionIdentity) -> String {
        var parts: [String] = []
        if let branch = identity.branchFact { parts.append("branch \(branch.summary)") }
        if let tty = identity.tty, !tty.isEmpty { parts.append("tty \(tty)") }
        if let pid = identity.claudePID { parts.append("claude pid \(pid)") }
        parts.append("session \(identity.sessionID)")
        return parts.joined(separator: "  ·  ")
    }

    static func existingLine(_ pairing: TerminalPairing?) -> String {
        guard let pairing else { return "No Ghostty tab is linked to this session yet." }
        let name = pairing.terminalName.map { "“\($0)” " } ?? ""
        return "Currently linked to \(name)terminal \(pairing.terminalID), "
             + "confirmed by you on \(PairingWindow.stamp.string(from: pairing.pairedAt))."
    }

    static func previewLine(_ snapshot: TerminalSnapshot, fingerprint: ProcessFingerprint?) -> String {
        var line = "Ghostty's selected tab: \(snapshot.summary)"
        if let tabID = snapshot.tabID { line += "\n(tab \(tabID)" }
        if let windowID = snapshot.windowID { line += ", window \(windowID))" }
        else if snapshot.tabID != nil { line += ")" }
        if let fingerprint { line += "\nGhostty pid \(fingerprint.pid)" }
        return line
    }

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Reading and confirming

    /// Ask Ghostty what is selected, and show it. Read-only.
    private func readSelected() {
        // A window the user has closed — by Escape, by the red button, or by our own Close — is
        // finished with. Nothing it still holds may act after that.
        guard let identity, !busy, isVisible else { return }
        busy = true
        let generation = self.generation
        statusLabel.stringValue = "Asking Ghostty…"
        confirmButton?.isEnabled = false
        readButton?.isEnabled = false
        runOffMain { [weak self] in
            guard let self else { return }
            // Taken on **both** sides of the read. Ghostty restarting during the read would
            // otherwise leave us pinning a tab id from the new run onto the old run's fingerprint.
            let before = self.ghostty.processIdentity()
            let result = self.ghostty.readSelectedTerminal()
            let after = self.ghostty.processIdentity()
            let fingerprint = (before != nil && after != nil && after!.matches(before!)) ? after : nil
            self.runOnMain {
                guard generation == self.generation else { return }
                self.busy = false
                self.readButton?.isEnabled = true
                guard self.identity?.sessionID == identity.sessionID else { return }
                switch result {
                case .success(let snapshot):
                    self.preview = snapshot
                    self.previewFingerprint = fingerprint
                    self.previewLabel.stringValue = PairingWindow.previewLine(snapshot, fingerprint: fingerprint)
                    self.statusLabel.stringValue = fingerprint == nil
                        ? "Ghostty answered, but the same run of Ghostty could not be identified either side of the read — linking is not safe."
                        : "Check this is the right tab, then confirm."
                    self.confirmButton?.isEnabled = fingerprint != nil
                case .failure(let failure):
                    self.preview = nil
                    self.previewFingerprint = nil
                    self.previewLabel.stringValue = "Nothing read."
                    self.statusLabel.stringValue = failure.explanation
                    self.confirmButton?.isEnabled = false
                }
            }
        }
    }

    /// Save the link — but only after checking that nothing moved while the window was open.
    private func confirm() {
        guard let identity, let preview, let previewFingerprint, !busy, isVisible else { return }
        guard let pid = identity.claudePID, let started = identity.claudePIDStartedAt else {
            statusLabel.stringValue = "This session's Claude process is not identified, so a link could not be pinned to it."
            return
        }
        // Probed now, not taken from the snapshot the window was opened with. A link pinned to a
        // process that has already died is a link to nothing.
        guard liveness.probe(pid: pid, startedAt: started) == .alive else {
            invalidate("This session's Claude process is no longer alive at the moment it was recorded, so nothing was linked.")
            return
        }
        busy = true
        let generation = self.generation
        statusLabel.stringValue = "Checking nothing has moved…"
        confirmButton?.isEnabled = false

        runOffMain { [weak self] in
            guard let self else { return }
            // Both sides of the re-read again, for the same reason: the answer and the run of
            // Ghostty it came from have to be the same incarnation.
            let fingerprintBefore = self.ghostty.processIdentity()
            let selectedNow = self.ghostty.readSelectedTerminal()
            let fingerprintAfter = self.ghostty.processIdentity()
            self.runOnMain {
                guard generation == self.generation else { return }
                self.busy = false
                guard self.identity?.sessionID == identity.sessionID else { return }

                guard let fingerprintBefore, let fingerprintNow = fingerprintAfter,
                      fingerprintNow.matches(fingerprintBefore),
                      fingerprintNow.matches(previewFingerprint) else {
                    self.invalidate("Ghostty has restarted since you read that tab. Read the selected tab again.")
                    return
                }

                // The session, re-checked against what the engine holds **now**. An id that has
                // been reused by a newer Claude process is a different session wearing the same
                // name, and pinning a link to it would send the next click to a stranger's tab.
                if let live = self.currentIdentity?(identity.sessionID) {
                    guard live.claudePID == pid, live.claudePIDStartedAt == started else {
                        self.invalidate("This session has been replaced by a new Claude process since you read that tab. "
                                        + "Nothing was linked — read the selected tab again.")
                        return
                    }
                } else if self.currentIdentity != nil {
                    self.invalidate("This session is no longer being tracked, so nothing was linked.")
                    return
                }

                // And probed again, because the read above may have taken seconds.
                guard self.liveness.probe(pid: pid, startedAt: started) == .alive else {
                    self.invalidate("This session's Claude process ended while Ghostty was being read, so nothing was linked.")
                    return
                }
                guard case .success(let snapshotNow) = selectedNow else {
                    self.invalidate("Ghostty's selected tab could not be re-read, so nothing was linked.")
                    return
                }
                guard snapshotNow.terminalID == preview.terminalID else {
                    // A different tab is selected now. Linking the one we previewed would be a
                    // silent switch; linking the new one would be linking something unread.
                    self.preview = snapshotNow
                    self.previewLabel.stringValue = PairingWindow.previewLine(snapshotNow, fingerprint: fingerprintNow)
                    self.invalidate("A different Ghostty tab is selected now. Nothing was linked — check this one and confirm again.")
                    self.confirmButton?.isEnabled = true
                    return
                }

                let pairing = TerminalPairing(
                    sessionID: identity.sessionID,
                    claudePID: pid,
                    claudePIDStartedAt: started,
                    tty: identity.tty,
                    terminalAppBundleID: GhosttyAdapter.bundleIdentifier,
                    terminalAppPID: fingerprintNow.pid,
                    terminalAppStartedAt: fingerprintNow.startedAt,
                    terminalID: snapshotNow.terminalID,
                    tabID: snapshotNow.tabID,
                    windowID: snapshotNow.windowID,
                    terminalName: snapshotNow.name,
                    workingDirectory: snapshotNow.workingDirectory,
                    pairedAt: Date(),
                    // Deliberately nil. `lastVerifiedAt` means "we navigated here and read back that
                    // it landed" — confirming a link is not that, and dating it here would make an
                    // unused link look proven.
                    lastVerifiedAt: nil,
                    provenance: "userConfirmed"
                )
                // The window says "linked" only after the caller reports the link is on disk. A
                // failed write that still showed success would be the worst kind of quiet: the user
                // believes navigation is set up, and the next click behaves as though it never was.
                guard self.onConfirm?(pairing) == true else {
                    self.invalidate("The link could not be saved, so nothing changed. "
                                    + (self.existing == nil ? "This session is still unlinked."
                                                            : "Its previous link is still in place."))
                    self.confirmButton?.isEnabled = true
                    return
                }
                self.existing = pairing
                self.existingLabel.stringValue = PairingWindow.existingLine(pairing)
                self.unlinkButton?.isEnabled = true
                self.statusLabel.stringValue = "Linked. Opening this session will now focus that exact tab."
            }
        }
    }

    private func invalidate(_ message: String) {
        statusLabel.stringValue = message
        confirmButton?.isEnabled = false
    }

    private func unlink() {
        guard let identity else { return }
        guard onUnlink?(identity.sessionID) == true else {
            statusLabel.stringValue = "The link could not be removed, so it is still in place."
            return
        }
        existing = nil
        existingLabel.stringValue = PairingWindow.existingLine(nil)
        unlinkButton?.isEnabled = false
        statusLabel.stringValue = "Unlinked. Opening this session will bring Ghostty forward, and you pick the tab."
    }

    // MARK: - The window

    private func build() {
        guard window == nil else { return }
        let window = EscapeClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Escape is a cancel here, not just a close: a read or a confirm still in flight is
        // abandoned, and **nothing is saved**. Walking away from this window has to be the same as
        // never having opened it.
        window.onCancel = { [weak self] in self?.close() }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        // This window's buttons are the same shared controls the panel uses, so it needs the same
        // movement delivered — otherwise an I-beam carried in from another application is only
        // corrected on entry, and taken straight back by whatever moves next.
        ClickCursor.prepare(window)

        func label(_ field: NSTextField, size: CGFloat, weight: NSFont.Weight = .regular, colour: NSColor = .labelColor, lines: Int = 0) -> NSTextField {
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = colour
            field.isSelectable = true            // ids are here to be read, and copied
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = lines
            field.preferredMaxLayoutWidth = 520
            return field
        }

        _ = label(sessionLabel, size: 14, weight: .semibold)
        _ = label(sessionDetail, size: 11, colour: .secondaryLabelColor)
        _ = label(existingLabel, size: 12)
        _ = label(instructions, size: 12, colour: .secondaryLabelColor)
        _ = label(previewLabel, size: 12, weight: .medium)
        _ = label(statusLabel, size: 12, colour: .secondaryLabelColor)

        let read = ClosureButton(title: "Read selected tab", target: nil, action: nil)
        read.bezelStyle = .rounded
        read.handler = { [weak self] in self?.readSelected() }
        read.setAccessibilityLabel("Ask Ghostty which tab is selected, and show it here")
        readButton = read

        let confirm = ClosureButton(title: "Confirm link", target: nil, action: nil)
        confirm.bezelStyle = .rounded
        confirm.keyEquivalent = "\r"
        confirm.isEnabled = false
        confirm.handler = { [weak self] in self?.confirm() }
        confirm.setAccessibilityLabel("Link this session to the Ghostty tab shown above")
        confirmButton = confirm

        let unlink = ClosureButton(title: "Unlink", target: nil, action: nil)
        unlink.bezelStyle = .rounded
        unlink.isEnabled = false
        unlink.handler = { [weak self] in self?.unlink() }
        unlink.setAccessibilityLabel("Remove the link between this session and a Ghostty tab")
        unlinkButton = unlink

        let close = ClosureButton(title: "Close", target: nil, action: nil)
        close.bezelStyle = .rounded
        close.handler = { [weak self] in self?.close() }
        close.setAccessibilityLabel("Close this window. It changes nothing on its own.")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [unlink, spacer, read, confirm, close])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [
            sessionLabel, sessionDetail, existingLabel, instructions, previewLabel, statusLabel, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        window.contentView = content
        self.window = window
    }

    /// Draw this window's own view into a bitmap. It captures nothing but itself.
    @discardableResult
    func debugWritePNG(to url: URL) -> Bool {
        guard let window, let view = window.contentView else { return false }
        // The window may never have been displayed, in which case its subviews are still at zero
        // size and a cached bitmap would be blank. Lay it out first.
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    // Used by `--uicheck`.
    var debugPreviewText: String { previewLabel.stringValue }
    var debugStatusText: String { statusLabel.stringValue }
    var debugExistingText: String { existingLabel.stringValue }
    var debugSessionDetail: String { sessionDetail.stringValue }
    var debugConfirmEnabled: Bool { confirmButton?.isEnabled ?? false }
    var debugButtons: [ClosureButton] {
        guard let root = window?.contentView else { return [] }
        return AttentionPanelController.buttons(in: root)
    }
    var debugWindowAcceptsMouseMoved: Bool { window?.acceptsMouseMovedEvents ?? false }
    var debugSelectableFields: [NSTextField] {
        guard let root = window?.contentView else { return [] }
        return AttentionPanelController.textFields(in: root).filter { $0.isSelectable }
    }
    func debugReadSelected() { readSelected() }
    func debugConfirm() { confirm() }
    func debugUnlink() { unlink() }

    /// Sends a real Escape through Cocoa's key-equivalent path — not a call to `close()`.
    ///
    /// The event is synthetic and delivered to this app's own window only. Nothing is posted to the
    /// system, no other application can see it, and no input is injected anywhere.
    @discardableResult
    func debugSendEscape() -> Bool {
        guard let window else { return false }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: "\u{1b}",
                                           charactersIgnoringModifiers: "\u{1b}",
                                           isARepeat: false, keyCode: 53) else { return false }
        return window.performKeyEquivalent(with: event)
    }

    /// The same path with Return, to prove Escape did not swallow the default action.
    @discardableResult
    func debugSendReturn() -> Bool {
        guard let window else { return false }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: "\r",
                                           charactersIgnoringModifiers: "\r",
                                           isARepeat: false, keyCode: 36) else { return false }
        return window.performKeyEquivalent(with: event)
    }

}
