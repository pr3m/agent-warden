import AppKit
import AgentAttentionCore

/// "Recent conversation" — one session's recent exchange, on request.
///
/// A separate, ordinary window rather than part of the panel, for three reasons: it is the only
/// surface that shows message content, it should be readable and selectable rather than glanceable,
/// and closing it must be an act of its own. Closing it dismisses nothing and changes nothing.
///
/// The transcript is read on a background queue when the window opens, and again only when the
/// **Refresh** button is pressed. Nothing here polls, caches to disk, or feeds the queue.
final class SessionContextWindow: NSObject, NSWindowDelegate {
    /// Go to this session's terminal tab.
    ///
    /// Takes the **full session id**, never the identity this window happened to open with: the
    /// caller resolves the session again at the moment of the click, so a session that has ended or
    /// been replaced under the same id is refused rather than navigated to. The result comes back
    /// through the completion, and nothing about the queue is touched on the way — opening a tab is
    /// not dealing with a request, and this window never dismisses or snoozes one.
    var onOpenSession: ((String, @escaping (ContextOpenResult) -> Void) -> Void)?
    /// Hand this session to the existing "Link Ghostty tab…" window. Used when there is no link, and
    /// offered again when a saved one turns out not to hold.
    var onLinkTerminal: ((String) -> Void)?
    /// Is a link saved for this session right now? Only affects wording.
    var linkStatus: ((String) -> Bool)?

    private var window: NSWindow?
    private let text = NSTextView()
    private let headingLabel = NSTextField(labelWithString: "")
    private let attentionLabel = NSTextField(labelWithString: "")
    /// Navigation outcomes only. Kept apart from `attentionLabel` so a failed jump can never be
    /// mistaken for a change in what the session is asking of you.
    private let navigationLabel = NSTextField(labelWithString: "")
    private var openButton: ClosureButton?
    private var linkButton: ClosureButton?
    private var identity: SessionIdentity?
    private var attention: AttentionItem?
    /// Bumped whenever this window is shown for a session or closed. A navigation result carrying an
    /// old generation is an answer to a question nobody is asking any more.
    private var generation = 0
    /// One request at a time. A second click while the first is in flight would be a second focus.
    private var openInFlight = false
    /// A saved link that did not hold. The offer to link again has to survive the state refresh
    /// that follows the failure — a remedy that disappears the moment it becomes relevant is worse
    /// than none.
    private var relinkOffered = false
    private let queue = DispatchQueue(label: "ai.wundamental.agent-warden.context", qos: .userInitiated)
    /// Where the read runs, and where its result lands. `--uicheck` swaps both for immediate ones so
    /// the same code can be driven without a run loop.
    private let runOffMain: (@escaping () -> Void) -> Void
    private let runOnMain: (@escaping () -> Void) -> Void
    /// The *same* query the command line uses. A second, more optimistic path in the UI is exactly
    /// how "nothing is being asked of you" gets said about a session nobody can vouch for.
    private let query: (String) -> SessionContextAnswer

    init(query: @escaping (String) -> SessionContextAnswer = { sessionID in
        let paths = AppPaths.resolved()
        return SessionContextQuery.run(
            sessionID: sessionID,
            store: EventStore(paths: paths),
            config: AttentionConfig.load(from: paths.configFile),
            claudeHome: SessionRegistry.defaultRoot()
        )
    }, runOffMain: ((@escaping () -> Void) -> Void)? = nil,
       runOnMain: ((@escaping () -> Void) -> Void)? = nil) {
        self.query = query
        let queue = DispatchQueue(label: "ai.wundamental.agent-warden.context.read", qos: .userInitiated)
        self.runOffMain = runOffMain ?? { work in queue.async(execute: work) }
        self.runOnMain = runOnMain ?? { work in DispatchQueue.main.async(execute: work) }
        super.init()
    }

    /// Drives the same logic without a run loop. Used only by `--uicheck`.
    static func synchronous(query: @escaping (String) -> SessionContextAnswer) -> SessionContextWindow {
        SessionContextWindow(query: query, runOffMain: { $0() }, runOnMain: { $0() })
    }

    func show(identity: SessionIdentity, attention: AttentionItem?) {
        generation += 1
        openInFlight = false
        relinkOffered = false
        self.identity = identity
        self.attention = attention
        build()
        headingLabel.stringValue = SessionContextWindow.heading(for: identity)
        attentionLabel.stringValue = "Checking this session…"
        navigationLabel.stringValue = ""
        text.string = "Reading the transcript…"
        updateOpenAction()
        window?.title = "Recent conversation — \(identity.displayName)"
        window?.makeKeyAndOrderFront(nil)
        // An ordinary window, so it may take focus; the bubble and panel still never do.
        NSApp.activate(ignoringOtherApps: true)
        load()
    }

    func close() {
        invalidateInFlightWork()
        window?.orderOut(nil)
    }

    /// The red button and ⌘W are closes too.
    ///
    /// `close()` is only the path our own button takes. Without this, a navigation or a transcript
    /// read still in flight would come back to a window the user has already dismissed and write
    /// into it — and the next time the window was opened for another session, that stale answer
    /// could be the first thing on screen.
    func windowWillClose(_ notification: Notification) {
        invalidateInFlightWork()
    }

    /// Everything in flight belongs to the window as it was; nothing here destroys the window, so
    /// it can be shown again immediately.
    private func invalidateInFlightWork() {
        generation += 1
        openInFlight = false
    }

    // MARK: - Going to the session's tab

    /// What the button says, and what it will do — stated before the click, not after.
    private func updateOpenAction() {
        guard let sessionID = identity?.sessionID else { return }
        let linked = linkStatus?(sessionID) ?? false
        openButton?.isEnabled = !openInFlight && onOpenSession != nil
        openButton?.toolTip = linked
            ? "Bring up the Ghostty tab you linked to this session. Nothing is dismissed or snoozed."
            : "This session has no linked tab yet — this opens the window where you pick it."
        openButton?.setAccessibilityLabel(linked
            ? "Open this session in its linked Ghostty tab"
            : "This session has no linked Ghostty tab yet. Opens the window where you link one.")
        // The relink button earns its place when linking is the thing to do next: either there is
        // no link, or the saved one has just been shown not to hold.
        linkButton?.isHidden = linked && !relinkOffered
        linkButton?.setAccessibilityLabel("Choose which Ghostty tab this session is running in")
    }

    private func openSession() {
        guard let sessionID = identity?.sessionID, let onOpenSession, !openInFlight else { return }
        openInFlight = true
        openButton?.isEnabled = false
        navigationLabel.stringValue = "Going to this session's tab…"
        let generation = self.generation
        onOpenSession(sessionID) { [weak self] result in
            guard let self else { return }
            // The window may have been closed, or moved to another session, while the terminal was
            // being asked. A result for the question that is no longer on screen changes nothing.
            guard generation == self.generation, self.identity?.sessionID == sessionID else { return }
            self.openInFlight = false
            switch result {
            case .landed(let message):
                self.navigationLabel.stringValue = message
            case .needsLink(let message):
                self.navigationLabel.stringValue = message
            case .failed(let message, let offerRelink):
                self.navigationLabel.stringValue = message
                if offerRelink { self.relinkOffered = true }
            }
            self.updateOpenAction()
            // The transcript and the attention line are deliberately untouched: a navigation that
            // failed says nothing about what the session is asking for, and losing the conversation
            // you were reading because a tab could not be focused would be its own small betrayal.
        }
    }

    /// Re-read the link state, e.g. after one has just been confirmed elsewhere.
    ///
    /// The conversation on screen is untouched: linking a tab is not a reason to lose your place in
    /// what you were reading.
    func refreshOpenAction() {
        guard identity != nil else { return }
        // A link that has just been confirmed answers the offer that was standing.
        if linkStatus?(identity?.sessionID ?? "") == true { relinkOffered = false }
        updateOpenAction()
        if linkStatus?(identity?.sessionID ?? "") == true, navigationLabel.stringValue.contains("linking window") {
            navigationLabel.stringValue = "Tab linked. Open session will go straight there now."
        }
    }

    private func linkTerminal() {
        guard let sessionID = identity?.sessionID else { return }
        onLinkTerminal?(sessionID)
        navigationLabel.stringValue = "Pick this session's tab in the linking window, then come back "
                                    + "and press Open session."
    }

    private func load() {
        guard let sessionID = identity?.sessionID else { return }
        // The session id alone is not enough. The same session can be closed and reopened while a
        // read is out, and the answer to the *previous* asking would then replace fresher content
        // with older content — for the same id, so an id check would wave it through.
        let generation = self.generation
        runOffMain { [weak self] in
            guard let self else { return }
            let answer = self.query(sessionID)
            self.runOnMain {
                guard generation == self.generation,
                      self.identity?.sessionID == sessionID else { return }
                self.attentionLabel.stringValue = SessionContextWindow.attentionLine(answer)
                self.text.string = SessionContextWindow.render(answer)
                self.text.scrollToEndOfDocument(nil)
            }
        }
    }

    // MARK: - Copy

    static func heading(for identity: SessionIdentity) -> String {
        var parts = [identity.displayName]
        if let branch = identity.branchFact { parts.append(branch.summary) }
        parts.append(identity.cwd)
        return parts.joined(separator: "  ·  ")
    }

    /// The authoritative state, stated as such and kept apart from anything in the transcript.
    ///
    /// It says *known* only when the shared trust model says so. A saved request from an app that is
    /// no longer running is still shown — it is a real record — but it is labelled as one rather
    /// than presented as live certainty.
    static func attentionLine(_ answer: SessionContextAnswer) -> String {
        let attention = answer.attention
        if let kind = attention.kind {
            var line = "\(kind): \(attention.reason ?? "")"
            line += attention.known ? "  — reported by a hook, and still open"
                                    : "  — a saved record; the queue could not be trusted just now"
            if attention.snoozed == true { line += " (snoozed)" }
            return line
        }
        if attention.known {
            return "No open request from this session. (From hooks — the conversation below is not evidence.)"
        }
        return "Whether this session needs you is unknown (\(attention.certainty)). "
             + "The conversation below is not evidence either way."
    }

    /// Attributed excerpts, in order, with what was and was not read spelled out.
    static func render(_ answer: SessionContextAnswer) -> String {
        var lines: [String] = []
        lines.append(SessionContextCopy.identityLine(answer.identity))
        lines.append("")
        guard let context = answer.context else {
            lines.append("No transcript was read.")
            lines.append("")
            for caveat in answer.attention.caveats { lines.append("• \(caveat)") }
            return lines.joined(separator: "\n")
        }
        return lines.joined(separator: "\n") + "\n" + render(context)
            + "\n" + answer.attention.caveats.map { "• \($0)" }.joined(separator: "\n")
    }

    static func render(_ context: SessionContext) -> String {
        var lines: [String] = []
        guard context.availability == .read else {
            lines.append(context.notes.first ?? "The transcript for this session could not be read.")
            lines.append("")
            lines.append("This does not change what the session is asking for. The state above comes "
                         + "from hooks and stands on its own.")
            return lines.joined(separator: "\n")
        }

        if context.messages.isEmpty {
            lines.append("No user or assistant text in the part of the transcript that was read.")
        }
        for message in context.messages {
            let stamp = message.at.map { SessionContextWindow.stamp.string(from: $0) } ?? "—"
            lines.append("\(message.role == "user" ? "You" : "Claude")  ·  \(stamp)")
            lines.append(message.excerpt)
            lines.append("")
        }

        if !context.questions.isEmpty {
            lines.append("— Questions found in the transcript —")
            for question in context.questions {
                lines.append(question.question)
                for option in question.options { lines.append("   • \(option)") }
                switch question.answered {
                case "answered": lines.append("   (answered)")
                case "cancelled": lines.append("   (cancelled or refused — not an answer)")
                default:
                    lines.append("   (no result seen in what was read — not evidence that one is owed)")
                }
                lines.append("")
            }
        }

        lines.append("— Read \(context.bytesRead / 1024) KiB at \(SessionContextWindow.stamp.string(from: context.readAt))"
                     + (context.tailTruncated ? ", tail only —" : ", whole file —"))
        if let newest = context.messages.last?.at {
            let age = max(0, Int(context.readAt.timeIntervalSince(newest)))
            lines.append("Newest message \(age)s before that read. Conversation freshness, not queue freshness.")
        }
        for note in context.notes { lines.append("• \(note)") }
        lines.append("Excerpts, not a summary. Thinking, tool inputs and tool results are excluded.")
        return lines.joined(separator: "\n")
    }

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: - The window

    private func build() {
        guard window == nil else { return }
        let window = EscapeClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // Escape means "I am done reading". It closes the window and nothing else: the conversation
        // is not a queue item, and closing it has never dismissed anything.
        window.onCancel = { [weak self] in self?.close() }
        window.isReleasedWhenClosed = false      // closing hides it; it is shown again as it was
        window.delegate = self
        window.center()
        // This window's buttons are the same shared controls the panel uses, so it needs the same
        // movement delivered — otherwise an I-beam carried in from another application is only
        // corrected on entry, and taken straight back by whatever moves next.
        ClickCursor.prepare(window)

        headingLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headingLabel.lineBreakMode = .byTruncatingMiddle
        headingLabel.isSelectable = true
        attentionLabel.font = .systemFont(ofSize: 12)
        attentionLabel.textColor = .secondaryLabelColor
        attentionLabel.isSelectable = true
        attentionLabel.lineBreakMode = .byWordWrapping
        attentionLabel.maximumNumberOfLines = 3

        text.isEditable = false
        text.isSelectable = true          // it is here to be read and copied
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isAutomaticQuoteSubstitutionEnabled = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false
        text.autoresizingMask = [.width]

        let open = ClosureButton(title: "Open session", target: nil, action: nil)
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.handler = { [weak self] in self?.openSession() }
        openButton = open

        let link = ClosureButton(title: "Link Ghostty tab…", target: nil, action: nil)
        link.bezelStyle = .rounded
        link.handler = { [weak self] in self?.linkTerminal() }
        link.isHidden = true
        linkButton = link

        let refresh = ClosureButton(title: "Refresh", target: nil, action: nil)
        refresh.bezelStyle = .rounded
        refresh.handler = { [weak self] in self?.load() }
        refresh.setAccessibilityLabel("Read this session's transcript again")

        let close = ClosureButton(title: "Close", target: nil, action: nil)
        close.bezelStyle = .rounded
        close.handler = { [weak self] in self?.close() }
        close.setAccessibilityLabel("Close this window. It changes nothing about the session.")

        navigationLabel.font = .systemFont(ofSize: 12)
        navigationLabel.textColor = .secondaryLabelColor
        navigationLabel.isSelectable = true
        navigationLabel.lineBreakMode = .byWordWrapping
        navigationLabel.maximumNumberOfLines = 3

        let buttons = NSStackView(views: [NSView(), link, open, refresh, close])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [headingLabel, attentionLabel, scroll, navigationLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            headingLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            attentionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            navigationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        window.contentView = content
        self.window = window
    }

    /// Draw this window's own view into a bitmap. It captures nothing but itself.
    @discardableResult
    func debugWritePNG(to url: URL) -> Bool {
        guard let window, let view = window.contentView else { return false }
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
    var debugBodyText: String { text.string }
    var debugHeading: String { headingLabel.stringValue }
    var debugAttentionLine: String { attentionLabel.stringValue }
    var debugNavigationLine: String { navigationLabel.stringValue }
    var debugIsVisible: Bool { window?.isVisible ?? false }
    var debugButtonTitles: [String] {
        guard let root = window?.contentView else { return [] }
        return AttentionPanelController.buttons(in: root).map(\.title)
    }
    var debugOpenEnabled: Bool { openButton?.isEnabled ?? false }
    /// The buttons this window actually built, so a check can drive their real event paths.
    var debugButtons: [ClosureButton] {
        guard let root = window?.contentView else { return [] }
        return AttentionPanelController.buttons(in: root)
    }
    var debugWindowAcceptsMouseMoved: Bool { window?.acceptsMouseMovedEvents ?? false }
    /// The text that is meant to keep its own I-beam: the transcript and the selectable identity
    /// lines. The cursor policy must leave these alone.
    var debugSelectableFields: [NSTextField] {
        guard let root = window?.contentView else { return [] }
        return AttentionPanelController.textFields(in: root).filter { $0.isSelectable }
    }
    var debugTranscriptIsSelectable: Bool { text.isSelectable && !text.isEditable }
    var debugOpenTooltip: String { openButton?.toolTip ?? "" }
    var debugOpenAccessibilityLabel: String { openButton?.accessibilityLabel() ?? "" }
    var debugLinkOffered: Bool { !(linkButton?.isHidden ?? true) }
    func debugClickOpen() { openSession() }
    func debugClickLink() { linkTerminal() }
    func debugClickRefresh() { load() }

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

    /// Closes exactly as the title-bar button and ⌘W do, through AppKit's own close machinery.
    func debugPerformNativeClose() { window?.performClose(nil) }
}

/// What came of asking to open a session's tab.
///
/// Three outcomes, because they need three different things from the person reading them: you are
/// there; you need to link a tab first; or it did not work and here is why.
enum ContextOpenResult {
    case landed(String)
    case needsLink(String)
    case failed(String, offerRelink: Bool)
}

/// Shared wording, so the window and the command line describe identity the same way.
enum SessionContextCopy {
    static func identityLine(_ identity: SessionContextAnswer.Identity) -> String {
        switch identity {
        case .verifiedLive: return "Tracked session, process alive at the recorded start time."
        case .processGone: return "Tracked session, but its process is gone — this is history, not now."
        case .unverified: return "Tracked session, process not verifiable — this may not be current."
        case .notTracked: return "Agent Warden is not tracking this session, so no transcript was read."
        }
    }
}
