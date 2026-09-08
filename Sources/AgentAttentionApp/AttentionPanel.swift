import AppKit
import AgentAttentionCore

/// One adjustable preference, named as the user would name it.
///
/// A closed set rather than a config mutation, so the panel can describe a change truthfully in a
/// failure message without knowing how it is stored.
enum PanelSetting {
    case soundEnabled(Bool)
    case speechEnabled(Bool)
    case chimeEnabled(Bool)
    case notifyOnWorkComplete(Bool)
    case notifyOnIdle(Bool)
    case includeHookMessages(Bool)
    case bubbleEnabled(Bool)
    case snoozeDurationSeconds(TimeInterval)

    var label: String {
        switch self {
        case .soundEnabled(let on): return on ? "Turning sound on" : "Muting"
        case .speechEnabled(let on): return on ? "Turning spoken alerts on" : "Turning spoken alerts off"
        case .chimeEnabled(let on): return on ? "Turning the chime on" : "Turning the chime off"
        case .notifyOnWorkComplete: return "That notification setting"
        case .notifyOnIdle: return "That notification setting"
        case .includeHookMessages: return "That wording setting"
        case .bubbleEnabled: return "The bubble setting"
        case .snoozeDurationSeconds: return "The snooze length"
        }
    }
}

/// Carries a closure into a menu item, which `NSMenuItem` cannot do on its own.
final class ClosureMenuItem: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// One session's row. The whole row is one click target, and it says so by lighting up under the
/// pointer — flat when it is not, so the list reads as a list rather than as a stack of cards.
final class SessionRowView: ClickableView {
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

/// The queue panel that expands from the bubble.
///
/// A non-activating panel: it never steals focus from the terminal or the editor, and it floats
/// above full-screen spaces so a session asking for approval is visible without switching desktops.
/// It is anchored to the bubble, so wherever the bubble has been dragged, the two read as one
/// control.
///
/// The layout gives the session's *name* the room. Everything technical — full id, tty, terminal,
/// what a click can actually do — lives behind Details, because a squeezed column of truncated
/// identifiers is unreadable and none of it is what you are looking for at a glance.
final class AttentionPanelController {
    var onActivate: ((AttentionItem) -> Void)?
    var onSnooze: ((AttentionItem) -> Void)?
    var onDismiss: ((AttentionItem) -> Void)?
    var onDismissAll: (() -> Void)?
    var onCopyResume: ((SessionIdentity) -> Void)?
    var onOpenSession: ((SessionState) -> Void)?
    var onCollapse: (() -> Void)?
    /// Applies one setting and reports whether it actually persisted. A `false` is shown as a
    /// failure rather than as a silent no-op, because a preference that did not save is a lie the
    /// next launch will tell.
    var onSettingChange: ((PanelSetting) -> Bool)?
    /// Play the chime once, because the user asked to hear it. Never called by anything else, and
    /// it changes no preference — hearing a sound and choosing to be alerted by it are two
    /// decisions, and only the user makes either.
    var onPreviewChime: (() -> Void)?
    /// Open the orchestration-contract window. Opening a window is all it does: nothing is chosen,
    /// read or written until the user acts inside it.
    var onShowContract: (() -> Void)?
    var onNeedsRedraw: (() -> Void)?
    /// Explicit request to read one session's recent conversation.
    var onShowContext: ((SessionIdentity) -> Void)?
    /// Explicit request to link this session to a Ghostty tab.
    var onLinkTerminal: ((SessionIdentity) -> Void)?
    /// Looks up the confirmed link for a session, so Details can describe it.
    var pairingLookup: ((String) -> TerminalPairing?)?

    /// Whether the list is capped or fully expanded. Presentation only — nothing is hidden from
    /// the counts, and collapsing never dismisses anything.
    private(set) var showAllSessions = false

    /// What the settings control currently shows. Set from the live config before each render, so
    /// the ticks in the menu are the file's state and not a second copy of it.
    var settings: AttentionConfig = .default

    private let panel: NSPanel
    private let container: NSStackView
    private let headerLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let statusLabel: NSTextField
    private let versionLabel: NSTextField
    private var statusResetWork: DispatchWorkItem?
    private let panelWidth: CGFloat = 380
    private var contentWidth: CGFloat { panelWidth - 24 }
    /// What a row's text may occupy: the panel's content, less the ⋯ button and the chain icon.
    private var rowTextWidth: CGFloat { contentWidth - 34 - 22 }
    private var lastRenderAt = Date()
    private var renderedRows: [SessionRowView] = []
    private var anchor: CGRect?
    /// The moment the current render describes. Job ages are relative to it.
    private var renderedAt = Date()
    private var renderedTTL: TimeInterval = 30 * 60

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Agent Warden sessions")

        // The window stays transparent so the corners can be round and the shadow can fall
        // outside them — but what the text sits on is an **opaque plate**, not a blur.
        //
        // It used to be an `NSVisualEffectView` with `.hudWindow` and `.behindWindow` blending,
        // which means the readability of every label depended on whatever page happened to be
        // underneath the panel. Over a white page the plate lightened and light-grey supporting
        // text washed out. Contrast is not something to leave to the wallpaper.
        panel.appearance = NSAppearance(named: .darkAqua)
        let effect = NSView()
        effect.wantsLayer = true
        effect.layer?.backgroundColor = AttentionPanelController.plateColor.cgColor
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        headerLabel = AttentionPanelController.label(size: 14, weight: .semibold,
                                                     color: AttentionPanelController.primaryColor)
        headerLabel.stringValue = AgentAttentionVersion.displayName
        subtitleLabel = AttentionPanelController.label(size: 11, weight: .regular, color: AttentionPanelController.supportingColor)
        subtitleLabel.maximumNumberOfLines = 2
        statusLabel = AttentionPanelController.label(size: 11, weight: .regular, color: AttentionPanelController.supportingColor)
        statusLabel.maximumNumberOfLines = 3
        versionLabel = AttentionPanelController.label(size: 10, weight: .regular,
                                                     color: AttentionPanelController.footerColor)
        versionLabel.maximumNumberOfLines = 1

        container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        container.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            container.topAnchor.constraint(equalTo: effect.topAnchor),
            container.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel.contentView = effect
        // Movement is half the cursor policy, and a borderless panel gets none without this.
        ClickCursor.prepare(panel)
    }

    // MARK: - Rendering

    func render(
        items: [AttentionItem],
        sessions: [SessionState],
        snoozedCount: Int,
        maxVisible: Int,
        now: Date,
        anchor: CGRect?,
        backgroundEvidenceTTL: TimeInterval = 30 * 60
    ) {
        renderedAt = now
        renderedTTL = backgroundEvidenceTTL
        self.anchor = anchor
        lastRenderAt = now
        container.arrangedSubviews.forEach { view in
            container.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        renderedRows = []

        // **One session, one row.** The queue and the session list used to be two views of the same
        // thing, so a session that needed you appeared twice — once as a card and once as a row.
        // Now every session appears exactly once, keyed by its full id, and its open request is the
        // second line of its own row.
        let itemsBySession = Dictionary(items.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = sessions.map { session in
            Row(session: session, item: itemsBySession[session.identity.sessionID],
                now: now, ttl: backgroundEvidenceTTL)
        }
        // A session with an open item but no session record would otherwise vanish.
        for item in items where !sessions.contains(where: { $0.identity.sessionID == item.sessionID }) {
            rows.append(Row(orphan: item, now: now))
        }
        rows.sort(by: Row.moreUrgent)

        let waiting = sessions.filter { $0.isWaitingOnBackgroundWork(at: now, ttl: backgroundEvidenceTTL) }.count
        let working = sessions.filter { $0.activity == .working }.count
        let awaitingFirstHook = sessions.filter { $0.isDiscoveredOnly }.count
        let uncertain = sessions.filter { AttentionPanelController.isUncertain($0, now: now, ttl: backgroundEvidenceTTL) }.count

        headerLabel.stringValue = AgentAttentionVersion.displayName
        // Needing you, waiting on its own work, and "we could not tell" are three different things
        // and are counted apart. "No attention needed" would be a claim; "no confirmed requests" is
        // what we actually know.
        var parts: [String] = [items.isEmpty ? "No confirmed requests"
                                             : "\(items.count) need\(items.count == 1 ? "s" : "") you"]
        if waiting > 0 { parts.append("\(waiting) on background work") }
        parts.append("\(working) working")
        if uncertain > 0 { parts.append("\(uncertain) uncertain") }
        if awaitingFirstHook > 0 { parts.append("\(awaitingFirstHook) awaiting first hook") }
        if snoozedCount > 0 { parts.append("\(snoozedCount) snoozed") }
        subtitleLabel.stringValue = parts.joined(separator: " · ")
        container.addArrangedSubview(headerRow(hasItems: !items.isEmpty))

        if rows.isEmpty {
            let calm = AttentionPanelController.label(size: 12, weight: .regular,
                                                      color: AttentionPanelController.primaryColor)
            calm.maximumNumberOfLines = 4
            calm.preferredMaxLayoutWidth = contentWidth
            calm.stringValue = AttentionPanelController.emptyStateLine()
            container.addArrangedSubview(fullWidth(calm))
        }

        // A single rule separates the two halves: does this session want something from you?
        // Everything below the line is still shown truthfully — quiet is not hidden.
        var drewSeparator = false
        let cap = max(maxVisible, 8)
        let visible = showAllSessions ? rows : Array(rows.prefix(cap))
        for row in visible {
            if !drewSeparator, !row.needsYou, visible.contains(where: { $0.needsYou }) {
                container.addArrangedSubview(separator())
                drewSeparator = true
            }
            let view = sessionRow(row)
            renderedRows.append(view)
            container.addArrangedSubview(view)
        }
        // Everything tracked stays reachable. The list is capped so the panel cannot grow taller
        // than the screen, and the cap is stated rather than silently applied.
        if rows.count > visible.count || showAllSessions {
            let hidden = rows.count - visible.count
            let disclosure = AttentionPanelController.smallButton(
                title: showAllSessions ? "Show fewer" : "Show all \(rows.count) sessions"
            ) { [weak self] in
                guard let self else { return }
                self.showAllSessions.toggle()
                self.onNeedsRedraw?()
            }
            disclosure.setAccessibilityLabel(
                showAllSessions ? "Show only the sessions that need you first"
                                : "Show all \(rows.count) tracked sessions")
            if hidden > 0 {
                let more = AttentionPanelController.label(size: 11, weight: .regular,
                                                          color: AttentionPanelController.supportingColor)
                more.stringValue = "+\(hidden) more tracked"
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let line = NSStackView(views: [more, spacer, disclosure])
                line.orientation = .horizontal
                line.alignment = .centerY
                line.spacing = 6
                container.addArrangedSubview(fullWidth(line))
            } else {
                container.addArrangedSubview(fullWidth(disclosure))
            }
        }

        container.addArrangedSubview(fullWidth(statusLabel))
        container.addArrangedSubview(footerRow())

        layoutAndPosition()
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return line
    }

    /// One session's place in the list, and everything the row needs to draw itself.
    struct Row {
        var identity: SessionIdentity
        var session: SessionState?
        var item: AttentionItem?
        /// The one-line state when there is no open request.
        var quietLine: String
        var rank: Int
        var needsYou: Bool

        init(session: SessionState, item: AttentionItem?, now: Date, ttl: TimeInterval) {
            self.identity = session.identity
            self.session = session
            self.item = item
            self.quietLine = AttentionPanelController.rowSubtitle(session, now: now, ttl: ttl)
            self.needsYou = item != nil
            self.rank = item?.kind.rank ?? Row.quietRank(session, now: now, ttl: ttl)
        }

        init(orphan item: AttentionItem, now: Date) {
            self.identity = item.identity
            self.session = nil
            self.item = item
            self.quietLine = "state unknown"
            self.needsYou = true
            self.rank = item.kind.rank
        }

        /// Below the line, order by how much is known — never by how long something has been quiet.
        static func quietRank(_ session: SessionState, now: Date, ttl: TimeInterval) -> Int {
            if session.isWaitingOnBackgroundWork(at: now, ttl: ttl) { return 20 }
            if session.activity == .working { return 15 }
            if AttentionPanelController.isUncertain(session, now: now, ttl: ttl) { return 10 }
            if session.isDiscoveredOnly { return 5 }
            return 1
        }

        /// Urgent first; then a stable order by name, so a re-render does not shuffle the list
        /// under the pointer while nothing has actually changed.
        static func moreUrgent(_ a: Row, _ b: Row) -> Bool {
            if a.rank != b.rank { return a.rank > b.rank }
            return a.identity.sessionID < b.identity.sessionID
        }
    }

    /// How fresh this list is on the left, which build drew it on the right.
    ///
    /// The version is read from `AgentAttentionVersion.string` — the same constant the binary
    /// reports for `--version` — so a panel can never claim to be a build it is not. There is no
    /// second copy of that number anywhere.
    ///
    /// Freshness is the moment this list was last redrawn, not a guess at how current the sessions
    /// are. Warden redraws on every hook event and on every sweep, so a timestamp that stops moving
    /// is itself the signal that something is wrong.
    private func footerRow() -> NSView {
        let freshness = AttentionPanelController.label(size: 10, weight: .regular,
                                                      color: AttentionPanelController.mutedColor)
        freshness.stringValue = "updated \(AttentionPanelController.clockString(lastRenderAt))"
        freshness.toolTip = "When this list was last redrawn. Warden redraws on every hook event and every sweep."
        freshness.setAccessibilityLabel("List last updated at \(AttentionPanelController.clockString(lastRenderAt))")

        versionLabel.stringValue = AgentAttentionVersion.string
        versionLabel.alignment = .right
        versionLabel.setAccessibilityLabel("\(AgentAttentionVersion.displayName) version \(AgentAttentionVersion.string)")
        versionLabel.toolTip = "The build of \(AgentAttentionVersion.displayName) that is running right now"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [freshness, spacer, versionLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        return fullWidth(row)
    }

    static func clockString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func fullWidth(_ view: NSView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return view
    }

    private func headerRow(hasItems: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(headerLabel)
        row.addArrangedSubview(spacer)

        if hasItems {
            let dismissAll = AttentionPanelController.smallButton(title: "Dismiss all") { [weak self] in
                self?.onDismissAll?()
            }
            dismissAll.setAccessibilityLabel("Dismiss all waiting sessions")
            row.addArrangedSubview(dismissAll)
        }

        row.addArrangedSubview(soundButton())
        row.addArrangedSubview(settingsButton())

        let collapse = AttentionPanelController.smallButton(title: "Collapse") { [weak self] in
            self?.onCollapse?()
        }
        collapse.setAccessibilityLabel("Collapse the panel back to the bubble")
        row.addArrangedSubview(collapse)

        // The summary gets its own full-width line. Sharing a row with two buttons is what cut
        // "1 waiting on background work" off mid-word.
        subtitleLabel.preferredMaxLayoutWidth = contentWidth

        let stack = NSStackView(views: [row, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        subtitleLabel.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return fullWidth(stack)
    }

    // MARK: - Sound and settings

    /// One click, one meaning: is Agent Warden allowed to make a noise?
    ///
    /// Muting is a master switch. It silences everything audible, including speech, without
    /// forgetting that speech was wanted — so turning sound back on restores exactly what was set
    /// before and never starts talking about something the user never enabled. Nothing that
    /// happened while muted is announced afterwards; the queue is not a recording.
    private func soundButton() -> ClosureButton {
        let on = settings.soundEnabled
        let button = ClosureButton(title: on ? "Sound" : "Muted", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        if let image = NSImage(systemSymbolName: on ? "speaker.wave.2.fill" : "speaker.slash.fill",
                               accessibilityDescription: nil) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        // Whichever way it draws, the state is readable: a symbol with a label, or the word itself.
        button.setAccessibilityLabel(on ? "Sound is on. Click to mute Agent Warden."
                                        : "Agent Warden is muted. Click to turn sound back on.")
        // The master switch permits sound; it does not create one. Saying so here is the difference
        // between "Sound" meaning "you will hear something" and meaning "not muted".
        button.toolTip = on
            ? (settings.soundIsOnButSilent
               ? "Sound is allowed, but no alert sound is switched on yet. Choose Attention chime in Settings."
               : "Sound is on. Click to mute everything audible — the chime and spoken alerts.")
            : "Muted — no chime and no speech. Click to restore your sound settings."
        button.handler = { [weak self] in
            guard let self else { return }
            self.applySetting(.soundEnabled(!on),
                              success: !on ? "Sound on — your previous settings are back in force"
                                           : "Muted — nothing audible until you turn it back on")
        }
        return button
    }

    /// Everything adjustable, in one menu, in the user's words.
    private func settingsButton() -> ClosureButton {
        let button = ClosureButton(title: "Settings", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        if let image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.setAccessibilityLabel("Settings")
        button.toolTip = "Sound, spoken alerts, which events raise a notification, and snooze length"
        button.handler = { [weak self, weak button] in
            guard let self, let button else { return }
            let menu = self.settingsMenu()
            if let present = button.menuPresenter { present(menu); return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
        }
        return button
    }

    func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func toggle(_ title: String, _ on: Bool, _ enabled: Bool = true, _ tip: String? = nil,
                    _ change: @escaping () -> Void) {
            let entry = NSMenuItem(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
            let holder = ClosureMenuItem(action: change)
            entry.target = holder
            entry.representedObject = holder      // keeps the target alive for the menu's lifetime
            entry.state = on ? .on : .off
            entry.isEnabled = enabled
            entry.toolTip = tip
            menu.addItem(entry)
        }

        toggle("Sound", settings.soundEnabled, true,
               "The master switch. Off means no sound at all, including speech.") { [weak self] in
            guard let self else { return }
            self.applySetting(.soundEnabled(!self.settings.soundEnabled))
        }
        toggle("Attention chime", settings.chimeEnabled, settings.soundEnabled,
               settings.soundEnabled ? "A short two-note sound when a session actually asks you for "
                                     + "something. Never for a finished turn or an idle prompt."
                                     : "Unavailable while muted. Your choice is remembered.") { [weak self] in
            guard let self else { return }
            self.applySetting(.chimeEnabled(!self.settings.chimeEnabled))
        }
        // Hearing it and choosing it are separate. This plays once, on this click, and changes
        // nothing — so the chime can be judged before it is switched on.
        let preview = NSMenuItem(title: "Preview chime", action: #selector(ClosureMenuItem.fire),
                                 keyEquivalent: "")
        let previewHolder = ClosureMenuItem(action: { [weak self] in self?.onPreviewChime?() })
        preview.target = previewHolder
        preview.representedObject = previewHolder
        preview.isEnabled = settings.soundEnabled
        preview.toolTip = settings.soundEnabled
            ? "Plays it once, now. Changes nothing."
            : "Unavailable while muted."
        menu.addItem(preview)

        toggle("Speak alerts aloud", settings.speechEnabled, settings.soundEnabled,
               settings.soundEnabled ? "Reads a new request out using the macOS voice."
                                     : "Unavailable while muted. Your choice is remembered.") { [weak self] in
            guard let self else { return }
            self.applySetting(.speechEnabled(!self.settings.speechEnabled))
        }
        if !settings.soundEnabled && (settings.speechEnabled || settings.chimeEnabled) {
            let what = settings.speechEnabled && settings.chimeEnabled ? "your alert sounds stay"
                     : settings.speechEnabled ? "speech stays" : "the chime stays"
            let note = NSMenuItem(title: "  (\(what) on, but silent while muted)",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        // "Sound" on its own only ever meant "not muted". Until something is actually set to make
        // a noise, say so — otherwise the master switch reads as a promise nothing keeps.
        if settings.soundIsOnButSilent {
            let note = NSMenuItem(title: "  No alert sound is on — turn on Attention chime to hear one",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())
        let what = NSMenuItem(title: "Tell me when…", action: nil, keyEquivalent: "")
        what.isEnabled = false
        menu.addItem(what)
        toggle("A turn finishes with nothing left running", settings.notifyOnWorkComplete, true,
               "Only when the evidence confirms the work finished. Never inferred from silence.") { [weak self] in
            guard let self else { return }
            self.applySetting(.notifyOnWorkComplete(!self.settings.notifyOnWorkComplete))
        }
        toggle("A session reports it is waiting at the prompt", settings.notifyOnIdle, true,
               "Raised by the session itself, not by how long it has been quiet.") { [weak self] in
            guard let self else { return }
            self.applySetting(.notifyOnIdle(!self.settings.notifyOnIdle))
        }
        // Said plainly, because turning both off is easy to misread as "Warden is off".
        if !settings.notifyOnWorkComplete && !settings.notifyOnIdle {
            let note = NSMenuItem(title: "  Approvals, questions and errors still come through",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        toggle("Use the session's own wording as the reason", settings.includeHookMessages, true,
               "Shows the text the session sent, instead of a standard label.") { [weak self] in
            guard let self else { return }
            self.applySetting(.includeHookMessages(!self.settings.includeHookMessages))
        }

        menu.addItem(.separator())
        let snoozeTitle = NSMenuItem(title: "Snooze for", action: nil, keyEquivalent: "")
        let snoozeMenu = NSMenu()
        for minutes in [5, 10, 30, 60] {
            let seconds = TimeInterval(minutes * 60)
            let entry = NSMenuItem(title: "\(minutes) minutes", action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
            let holder = ClosureMenuItem(action: { [weak self] in
                self?.applySetting(.snoozeDurationSeconds(seconds))
            })
            entry.target = holder
            entry.representedObject = holder
            entry.state = abs(settings.snoozeDurationSeconds - seconds) < 1 ? .on : .off
            snoozeMenu.addItem(entry)
        }
        snoozeTitle.submenu = snoozeMenu
        menu.addItem(snoozeTitle)

        toggle("Show the floating bubble", settings.bubbleEnabled, true,
               "The menu bar item stays either way.") { [weak self] in
            guard let self else { return }
            self.applySetting(.bubbleEnabled(!self.settings.bubbleEnabled))
        }

        menu.addItem(.separator())
        // Named for what it is rather than for where it is kept: the file lives wherever the user
        // put it, and this app has no opinion about that.
        let contract = NSMenuItem(title: settings.orchestrationContractPath == nil
                                      ? "Orchestration contract… (none chosen)"
                                      : "Orchestration contract…",
                                  action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        let contractHolder = ClosureMenuItem(action: { [weak self] in self?.onShowContract?() })
        contract.target = contractHolder
        contract.representedObject = contractHolder
        contract.toolTip = "The working agreement this app and its consumers read. "
            + "Choose, replace or clear the document; it is never changed here."
        menu.addItem(contract)
        return menu
    }

    /// Applies a setting and says what actually happened — including when it did not save.
    func applySetting(_ change: PanelSetting, success: String? = nil) {
        guard let onSettingChange else {
            flash("That setting could not be changed — settings are not connected to this panel.")
            return
        }
        if onSettingChange(change) {
            if let success { flash(success) }
        } else {
            flash("\(change.label) could not be saved. Nothing was changed on disk.")
        }
    }

    // MARK: - One row per session

    /// A row: the name, one line of state or the open request, and an always-present ⋯ menu.
    ///
    /// The row *is* the primary action, and what that action does depends on what we can honestly
    /// offer. A linked session navigates to its tab. An unlinked one opens its recent conversation,
    /// from where it can be linked. The tooltip and the accessibility label say which, because a
    /// click that does something other than what you expected is worse than a button you can see.
    /// Has this row's request not been read yet? A row with no request is never "new".
    private func isUnseenRow(_ row: Row) -> Bool { row.item?.isUnseen == true }

    private func sessionRow(_ row: Row) -> SessionRowView {
        let identity = row.identity
        let pairing = pairingLookup?(identity.sessionID)
        let primary = AttentionPanelController.primaryAction(identity: identity, pairing: pairing)

        let view = SessionRowView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.onClick = { [weak self] in
            guard let self else { return }
            switch primary {
            case .openLinkedTab, .bringTerminalForward:
                // The **item** first, whenever the row has one. A row usually has both a session
                // record and an open request, and handing over only the session dropped the item id
                // on the floor — so nothing could be marked read or moved down the list, and a row
                // kept its unread dot after you had plainly just clicked it and jumped to its tab.
                if let item = row.item { self.onActivate?(item) }
                else if let session = row.session { self.onOpenSession?(session) }
            case .showContext:
                self.onShowContext?(identity)
            }
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        if isUnseenRow(row) { view.setAccessibilityValue("Not read yet") }

        let name = AttentionPanelController.label(size: 13, weight: .semibold,
                                                  color: AttentionPanelController.primaryColor)
        // A dot on the rows you have not read yet, so the list answers "what is new here?" without
        // being counted or opened. Drawn into the name rather than beside it: the name owns a fixed
        // width, and a sibling view would push it or truncate it. Marks are cleared when the panel
        // closes, not when it opens — see `markVisibleAsSeen`.
        // What the tab is called wins over what the folder is called.
        //
        // The old fallback was the worktree directory, because the tab title was unreachable — so
        // four sessions in one repository all read "Redmy" while their tabs plainly said
        // `client-info t1`, `release prep` and `velocity analysis`. A tab title is not a derived
        // name: somebody chose it. It is only used when this session is *linked* to that tab, so it
        // is the name of this session's own terminal and not the closest-looking one.
        let displayName = TabName.readable(pairing?.terminalName) ?? identity.readableName
        let isUnseen = row.item?.isUnseen == true
        if isUnseen {
            let marked = NSMutableAttributedString(
                string: "● ", attributes: [.foregroundColor: AttentionPanelController.unseenColor])
            marked.append(NSAttributedString(
                string: displayName,
                attributes: [.foregroundColor: AttentionPanelController.primaryColor]))
            marked.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                range: NSRange(location: 0, length: marked.length))
            name.attributedStringValue = marked
        } else {
            name.stringValue = displayName
        }
        name.maximumNumberOfLines = 2
        name.preferredMaxLayoutWidth = rowTextWidth
        name.widthAnchor.constraint(equalToConstant: rowTextWidth).isActive = true

        // Second line: the genuine request if there is one, else the quiet state. Never both, and
        // never a duplicate of the same session somewhere else in the list.
        let detail = NSStackView()
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 1

        if let item = row.item {
            // The branch belongs on every row, not only the quiet ones. Which worktree is asking is
            // half the answer to "which of these is it" — and a row that needs you is exactly when
            // that matters. One short line, above the request, and nothing else added.
            if let branch = AttentionPanelController.branchLine(identity) {
                let where_ = AttentionPanelController.label(size: 10, weight: .regular,
                                                            color: AttentionPanelController.mutedColor)
                where_.stringValue = branch
                where_.maximumNumberOfLines = 1
                where_.lineBreakMode = .byTruncatingMiddle
                where_.widthAnchor.constraint(equalToConstant: rowTextWidth).isActive = true
                detail.addArrangedSubview(where_)
            }
            let headline = AttentionPanelController.label(size: 11, weight: .medium,
                                                          color: AttentionPanelController.headlineColor(item.kind))
            // An acceptance checkpoint says what is wanted, not just that something is. "Waiting
            // for you" and "waiting for you to test it" are different next steps.
            headline.stringValue = item.awaitsUserAcceptance ? "Waiting for you to test it"
                                                             : item.kind.label
            detail.addArrangedSubview(headline)
            // The second line only earns its place when it says something the label does not.
            // "Asked you a question" under "Asked you a question" is noise, and noise is what the
            // old two-view layout was full of.
            let extra = AttentionPanelController.detailLine(item)
            if !extra.isEmpty {
                let reason = AttentionPanelController.label(size: 11, weight: .regular,
                                                            color: AttentionPanelController.supportingColor)
                reason.stringValue = extra
                reason.maximumNumberOfLines = 2
                reason.preferredMaxLayoutWidth = rowTextWidth
                reason.widthAnchor.constraint(equalToConstant: rowTextWidth).isActive = true
                detail.addArrangedSubview(reason)
            }
        } else {
            let state = AttentionPanelController.label(size: 11, weight: .regular,
                                                       color: AttentionPanelController.supportingColor)
            state.stringValue = row.quietLine
            state.maximumNumberOfLines = 2
            state.preferredMaxLayoutWidth = rowTextWidth
            state.widthAnchor.constraint(equalToConstant: rowTextWidth).isActive = true
            detail.addArrangedSubview(state)
        }

        // The third line, and a third question: what is running *behind* this session. Kept apart
        // from the request and from the state on purpose — "needs your approval" and "a monitor is
        // running" are both true at once, and collapsing them loses one of them.
        if let background = AttentionPanelController.backgroundLine(row.session, now: renderedAt, ttl: renderedTTL) {
            let jobs = AttentionPanelController.label(size: 10, weight: .regular,
                                                      color: AttentionPanelController.mutedColor)
            jobs.stringValue = background
            jobs.maximumNumberOfLines = 1
            jobs.lineBreakMode = .byTruncatingTail
            jobs.widthAnchor.constraint(equalToConstant: rowTextWidth).isActive = true
            detail.addArrangedSubview(jobs)
        }

        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let overflow = overflowButton(row: row, pairing: pairing)
        // Linking is a Ghostty-only arrangement, so the chain appears only where it means something.
        // A disabled icon inside a clickable row would be a control that claims nothing and blocks
        // the row's own click.
        let showsChain = onLinkTerminal != nil
            && TerminalTarget.normalizedTermProgram(identity) == "ghostty"
        let line = showsChain
            ? NSStackView(views: [texts, chainButton(identity: identity, pairing: pairing), overflow])
            : NSStackView(views: [texts, overflow])
        line.orientation = .horizontal
        line.alignment = .top
        line.spacing = 6
        line.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            line.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            line.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            view.widthAnchor.constraint(equalToConstant: contentWidth),
        ])

        let spoken = AttentionPanelController.rowAccessibilityLabel(row, primary: primary)
        view.setAccessibilityLabel(spoken)
        view.toolTip = primary.consequence
        return view
    }

    /// What clicking the row will actually do. Named, because it differs per session.
    enum PrimaryAction {
        case openLinkedTab
        case bringTerminalForward
        case showContext

        var consequence: String {
            switch self {
            case .openLinkedTab: return "Open the Ghostty tab you linked to this session"
            case .bringTerminalForward: return "Bring this session's terminal forward — you pick the tab"
            case .showContext: return "Show this session's recent conversation, and offer to link its tab"
            }
        }
    }

    static func primaryAction(identity: SessionIdentity, pairing: TerminalPairing?) -> PrimaryAction {
        if pairing != nil { return .openLinkedTab }
        // Ghostty without a link cannot be navigated to exactly, so the useful thing is context —
        // which is also where linking is offered. Other terminals can still be raised.
        if TerminalTarget.normalizedTermProgram(identity) == "ghostty" { return .showContext }
        return TerminalTarget.plan(for: identity).confidence == .none ? .showContext : .bringTerminalForward
    }

    static func rowAccessibilityLabel(_ row: Row, primary: PrimaryAction) -> String {
        var parts = [row.identity.readableName]
        if let item = row.item {
            parts.append("\(item.kind.label): \(item.reasonLine)")
            if item.snoozedUntil != nil { parts.append("snoozed") }
        } else {
            parts.append(row.quietLine)
        }
        parts.append(primary.consequence)
        return parts.joined(separator: ". ")
    }

    /// A small chain, saying what is known about this session's link — and nothing more.
    ///
    /// The state is read from what is already on disk: no Automation call is made to draw a row, so
    /// a picture of the queue never depends on a terminal answering. That also bounds what it may
    /// claim. **Saved is not verified**: it means a link exists and still names this session's
    /// Claude process, not that the tab is still open. Only a navigation that lands proves that.
    ///
    /// Clicking it always goes to the same pairing window the ⋯ menu uses, for this exact session.
    /// It never navigates, dismisses or snoozes anything.
    private func chainButton(identity: SessionIdentity, pairing: TerminalPairing?) -> ClosureButton {
        let state = SessionLinkState.of(pairing: pairing, identity: identity)
        let button = ClosureButton(title: "", target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: AttentionPanelController.chainSymbol(state),
                               accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.contentTintColor = AttentionPanelController.chainColour(state)
        button.alphaValue = state == .none ? 0.6 : 1.0
        button.toolTip = AttentionPanelController.chainTooltip(state, pairing: pairing)
        button.setAccessibilityLabel(AttentionPanelController.chainAccessibilityLabel(state, identity: identity))
        // A hit target you can actually hit, without a full-sized button's footprint.
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        button.handler = { [weak self] in self?.onLinkTerminal?(identity) }
        return button
    }

    static func chainSymbol(_ state: SessionLinkState) -> String {
        switch state {
        case .none: return "link"                  // a chain, quietly: nothing is linked yet
        case .saved: return "link.circle.fill"     // a chain, closed
        case .stale: return "link.badge.plus"      // a chain that needs attending to
        }
    }

    static func chainColour(_ state: SessionLinkState) -> NSColor {
        switch state {
        case .none: return mutedColor
        case .saved: return completedColor
        case .stale: return urgentColor
        }
    }

    static func chainTooltip(_ state: SessionLinkState, pairing: TerminalPairing?) -> String {
        switch state {
        case .none:
            return "No Ghostty tab is linked to this session. Click to pick one."
        case .saved:
            let tab = pairing.map { $0.terminalName.map { name in "“\(name)” " } ?? "" } ?? ""
            let id = pairing?.terminalID ?? "?"
            return "Linked to \(tab)Ghostty terminal \(id), because you said so. "
                 + "Whether that tab is still open is only known when opening it lands. Click to change or remove."
        case .stale:
            return "This session is running under a different Claude process than the saved link names, "
                 + "so the link cannot be right. Click to link it again."
        }
    }

    static func chainAccessibilityLabel(_ state: SessionLinkState, identity: SessionIdentity) -> String {
        switch state {
        case .none: return "\(identity.readableName): no Ghostty tab linked. Opens the linking window."
        case .saved: return "\(identity.readableName): a Ghostty tab is linked, not re-checked. Opens the linking window."
        case .stale: return "\(identity.readableName): the saved Ghostty link no longer matches this session. Opens the linking window."
        }
    }

    /// The ⋯ menu. Always present, so its position never moves, and always describing only what
    /// applies to this session.
    private func overflowButton(row: Row, pairing: TerminalPairing?) -> ClosureButton {
        let identity = row.identity
        let button = AttentionPanelController.smallButton(title: "•••") { }
        button.setAccessibilityLabel("More actions for \(identity.readableName)")
        button.toolTip = "Recent conversation, linking, snooze and dismiss"
        button.handler = { [weak self, weak button] in
            guard let self, let button else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false

            let context = NSMenuItem(title: "Recent conversation…",
                                     action: #selector(ClosureButton.fireMenuContext(_:)), keyEquivalent: "")
            context.target = button
            context.representedObject = identity
            button.contextHandler = { [weak self] in self?.onShowContext?($0) }
            menu.addItem(context)

            if TerminalTarget.normalizedTermProgram(identity) == "ghostty", self.onLinkTerminal != nil {
                let link = NSMenuItem(title: pairing == nil ? "Link Ghostty tab…" : "Change or remove linked tab…",
                                      action: #selector(ClosureButton.fireMenuLink(_:)), keyEquivalent: "")
                link.target = button
                link.representedObject = identity
                button.linkHandler = { [weak self] in self?.onLinkTerminal?($0) }
                menu.addItem(link)
            }

            // Snooze and dismiss act on the *notification*, and only exist when there is one.
            if let item = row.item {
                menu.addItem(.separator())
                let snooze = NSMenuItem(title: "Snooze this notification",
                                        action: #selector(ClosureButton.fireMenuItemAction(_:)), keyEquivalent: "")
                snooze.target = button
                snooze.representedObject = item
                menu.addItem(snooze)

                let dismiss = NSMenuItem(title: "Dismiss this notification",
                                         action: #selector(ClosureButton.fireMenuSecondaryAction(_:)), keyEquivalent: "")
                dismiss.target = button
                dismiss.representedObject = item
                dismiss.toolTip = "Removes the notification only. The session and its work are untouched."
                menu.addItem(dismiss)

                button.itemHandler = { [weak self] in self?.onSnooze?($0) }
                button.secondaryItemHandler = { [weak self] in self?.onDismiss?($0) }
            }

            menu.addItem(.separator())
            if self.onCopyResume != nil {
                let copy = NSMenuItem(title: "Copy session details and resume command",
                                      action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
                let holder = ClosureMenuItem(action: { [weak self] in self?.onCopyResume?(identity) })
                copy.target = holder
                copy.representedObject = holder
                copy.toolTip = "Puts the project, folder, full session id and `claude --resume …` on the clipboard"
                menu.addItem(copy)
            }

            let details = NSMenuItem(title: "Details", action: nil, keyEquivalent: "")
            details.submenu = self.detailsMenu(for: identity, pairing: pairing, row: row)
            menu.addItem(details)

            if let present = button.menuPresenter { present(menu); return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
        }
        return button
    }

    /// Everything technical, one level down: full id, folder, branch, terminal, link, click target.
    private func detailsMenu(for identity: SessionIdentity, pairing: TerminalPairing?, row: Row) -> NSMenu {
        let menu = NSMenu()
        func line(_ text: String) {
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        line(identity.readableName)
        line("session  \(identity.sessionID)")
        let jobs = AttentionPanelController.jobLines(row.session, now: renderedAt, ttl: renderedTTL)
        if !jobs.isEmpty {
            menu.addItem(.separator())
            // What is running behind this session, one line each. The coverage line is not a
            // formality: this list is what we have heard about, never a complete inventory.
            line("background jobs (\(row.session?.jobs.coverage.rawValue ?? "unknown") coverage)")
            jobs.prefix(12).forEach { line("  " + $0) }
            if jobs.count > 12 { line("  …and \(jobs.count - 12) more") }
            if let evicted = row.session?.jobs.evicted, evicted > 0 {
                line("  \(evicted) older job(s) dropped to stay bounded")
            }
            menu.addItem(.separator())
        }
        line("folder   \(identity.cwd)")
        if let generated = identity.generatedLabel {
            line("label    \(generated)  (client-generated\(identity.titleSource.map { ", \($0)" } ?? ""))")
        }
        if let branch = identity.branchFact {
            let age = branch.source == "git"
                ? " · read \(AttentionPanelController.ageString(from: branch.readAt, to: Date())) ago"
                : ""
            line("branch   \(branch.summary)\(age)")
        }
        line("terminal \(identity.terminalName)")
        if let tty = identity.tty { line("tty      \(tty)") }
        if let pid = identity.claudePID { line("claude   pid \(pid)") }
        if let pairing {
            line("linked   Ghostty terminal \(pairing.terminalID)"
                 + (pairing.terminalName.map { " · “\($0)”" } ?? "") + " · you confirmed it")
            line("verified \(pairing.lastVerifiedAt == nil ? "never navigated yet" : "last landed successfully")")
        }
        line("state    \(row.quietLine)")
        menu.addItem(.separator())
        line(TerminalTarget.plan(for: identity, pairing: pairing).confidence.cardLabel)
        return menu
    }

    /// The branch, when we read it from the directory, and then the state.
    ///
    /// Only a `git` reading gets to appear here. The transcript's branch is stamped at session start
    /// and was observed saying `main` for five sessions that were each on their own `cs/…` branch —
    /// showing that on the row would be worse than showing nothing.
    static func rowSubtitle(_ session: SessionState, now: Date, ttl: TimeInterval) -> String {
        let state = stateLine(session, now: now, ttl: ttl)
        guard let branch = branchLine(session.identity) else { return state }
        return "\(branch) · \(state)"
    }

    /// One short line. The row has room for a phrase, not a sentence; the full reading is in
    /// Details and, for background work, in the section above the list.
    static func stateLine(_ session: SessionState, now: Date, ttl: TimeInterval) -> String {
        if session.isDiscoveredOnly { return "found running · awaiting first hook" }
        // The evidence's own wording: counts and types, never a task description or a command.
        if session.isWaitingOnBackgroundWork(at: now, ttl: ttl) {
            return session.background?.summaryLine ?? "on background work"
        }
        if let background = session.background, background.hasFailure,
           !background.isStale(at: now, after: ttl) {
            return background.summaryLine
        }
        if isUncertain(session, now: now, ttl: ttl) { return "turn ended · state not confirmed" }
        switch session.activity {
        case .working: return "working"
        case .awaitingUser: return session.currentItemID != nil ? "needs you" : "waiting at the prompt"
        case .backgroundWaiting: return "paused on background work"
        case .discovered: return "found running · awaiting first hook"
        case .ended: return "ended"
        case .unknown: return "state unknown"
        }
    }

    // MARK: - Status line

    func flash(_ message: String, seconds: TimeInterval = 6) {
        statusLabel.stringValue = message
        statusLabel.toolTip = message
        statusResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.statusLabel.stringValue = ""
            self?.statusLabel.toolTip = nil
        }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Visibility

    func show() {
        layoutAndPosition()
        panel.orderFrontRegardless()
    }

    func hide() {
        // Leaving the pointer as a hand over a panel that has just vanished would be the classic
        // stuck-cursor bug.
        NSCursor.arrow.set()
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Geometry

    func layoutAndPosition() {
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: panelWidth, height: max(fitting.height, 80))

        let target: CGRect
        if let anchor {
            target = BubbleGeometry.panelFrame(panelSize: size, bubbleFrame: anchor, in: visible)
        } else {
            target = BubbleGeometry.clamp(
                CGRect(x: visible.maxX - size.width - 16, y: visible.minY + 16,
                       width: size.width, height: size.height),
                in: visible
            )
        }
        panel.setFrame(target, display: true)
    }

    // MARK: - Small helpers

    /// The surface everything in the panel is drawn on, and the colours that have to be legible
    /// against **it** — not against whatever happens to be behind the window.
    ///
    /// Every value is sRGB, stated exactly, so what a contrast check measures is what is drawn. The
    /// window's appearance is pinned to dark, so a system switch to Light cannot resolve a semantic
    /// label into near-black on this plate. Nothing here leaks outside the panel and the bubble.
    ///
    /// Measured against `plateColor`, these are 13.4 : 1 (primary), 10.5 : 1 (supporting),
    /// 6.8 : 1 (muted), 6.0 : 1 (footer), 9.4 : 1 (urgent) and 9.7 : 1 (complete) — all well over
    /// the 4.5 : 1 floor for body text, and the check that says so measures the rendered surface
    /// rather than trusting this comment.
    static let plateColor = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1.0)
    static let primaryColor = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1.0)
    /// The "you have not read this" dot. The same accent as the badge, because it means the same
    /// thing in a different place — and nothing else in the panel uses it.
    static let unseenColor = NSColor.systemOrange
    static let supportingColor = NSColor(srgbRed: 0.82, green: 0.82, blue: 0.82, alpha: 1.0)
    static let headingColor = NSColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1.0)
    /// The footer only: quieter than supporting text, still well over the floor.
    static let mutedColor = NSColor(srgbRed: 0.66, green: 0.66, blue: 0.66, alpha: 1.0)
    static let footerColor = NSColor(srgbRed: 0.62, green: 0.62, blue: 0.62, alpha: 1.0)
    /// The one line in a row that says a session is asking for something.
    static let urgentColor = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.42, alpha: 1.0)
    /// A finished turn is news, not a demand. Same row, same place, calm colour — so a glance at
    /// the list separates "deal with me" from "this one is done" without reading a word.
    static let completedColor = NSColor(srgbRed: 0.62, green: 0.84, blue: 0.68, alpha: 1.0)

    /// Every colour this panel puts on the plate, with the floor each one has to clear. Used by the
    /// readability check, so adding a colour without checking it is not something that can be
    /// forgotten quietly.
    static var measuredColors: [(name: String, color: NSColor, floor: Double)] {
        [("primary", primaryColor, Contrast.textFloor),
         ("heading", headingColor, Contrast.textFloor),
         ("supporting", supportingColor, Contrast.textFloor),
         ("muted", mutedColor, Contrast.textFloor),
         ("footer", footerColor, Contrast.textFloor),
         ("urgent request", urgentColor, Contrast.textFloor),
         ("completed", completedColor, Contrast.textFloor),
         ("accent", BubbleView.badgeColor, Contrast.controlFloor)]
    }

    /// The colour of a row's request line. Styling only: what raises a notification, and what the
    /// header counts, are decided in the engine and are untouched by this.
    static func headlineColor(_ kind: AttentionKind) -> NSColor {
        kind == .workComplete ? completedColor : urgentColor
    }

    /// What is running behind this session, in one short line — or nothing at all.
    ///
    /// The registry comes first because it is per-job and current; the `Stop` snapshot is the
    /// fallback, and says "last seen" because that is what a photograph of a past moment is. A
    /// stale reading produces no line rather than a confident one.
    static func backgroundLine(_ session: SessionState?, now: Date, ttl: TimeInterval) -> String? {
        guard let session else { return nil }
        if let live = session.jobs.summary(at: now, staleAfter: ttl) { return live }
        guard let evidence = session.background, evidence.isWaitingOnBackgroundWork,
              !evidence.isStale(at: now, after: ttl) else { return nil }
        let running = evidence.running
        if running == 0, evidence.crons > 0 {
            return evidence.crons == 1 ? "1 scheduled wakeup pending"
                                       : "\(evidence.crons) scheduled wakeups pending"
        }
        return running == 1 ? "1 background job" : "\(running) background jobs"
    }

    /// One line per job, for the Details submenu. Identifiers and vocabulary; never a command.
    static func jobLines(_ session: SessionState?, now: Date, ttl: TimeInterval) -> [String] {
        guard let session, !session.jobs.jobs.isEmpty else { return [] }
        return session.jobs.jobs.map { job in
            let age = ageString(from: job.observedAt, to: now)
            let kind = job.kind == .unknown ? (job.typeLabel ?? "job") : job.kind.rawValue
            let stale = job.isStale(at: now, after: ttl) ? " · last seen" : ""
            return "\(String(job.identity.taskID.prefix(12)))  \(kind) · \(job.state.rawValue) · \(age)\(stale)"
        }
    }

    /// The current branch, when we read it from the directory ourselves.
    ///
    /// Only a `git` reading qualifies. The transcript's branch is stamped at session start and was
    /// observed saying `main` for five sessions that were each on their own `cs/…` branch.
    static func branchLine(_ identity: SessionIdentity) -> String? {
        guard let branch = identity.branchFact, branch.source == "git" else { return nil }
        switch branch.state {
        case "branch": return branch.branch
        case "detached", "notARepository": return branch.summary
        default: return nil            // denied, timed out: say nothing rather than something wrong
        }
    }

    /// What the row adds under the request's own label, if anything.
    ///
    /// Compared without case or punctuation, because "Asked you a question" and "Asked you a
    /// question." are the same sentence and printing both is just a taller row.
    static func detailLine(_ item: AttentionItem) -> String {
        let snoozed = item.snoozedUntil != nil ? "snoozed" : ""
        func normalised(_ text: String) -> String {
            text.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }
        let reason = item.reasonLine
        guard normalised(reason) != normalised(item.kind.label) else { return snoozed }
        return snoozed.isEmpty ? reason : "\(reason)  ·  \(snoozed)"
    }

    /// A session whose turn ended with nothing confirming how.
    ///
    /// Uses the same rule as the status report — `SessionState.attentionCertainty` — so the panel
    /// and `aa-status` cannot disagree about the same session. Uncertainty is passive everywhere:
    /// it is counted and named, and it never raises a badge, a sound or an alert.
    static func isUncertain(_ session: SessionState, now: Date, ttl: TimeInterval) -> Bool {
        session.attentionCertainty(at: now, ttl: ttl) == .uncertain
    }

    /// Shown only when there is genuinely nothing to list — no sessions and no open requests.
    static func emptyStateLine() -> String {
        "No Claude Code sessions are being tracked. A session appears here the moment it reports "
        + "through a hook, or the moment a scan finds it running."
    }

    static func label(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        // A label is not editable text; it must not offer an I-beam or take a click.
        field.isSelectable = false
        field.isEditable = false
        // Wrap by default. `NSTextField` otherwise runs off the end of its width and simply stops,
        // which is how "1 awaiting first hook" became "1 awaiti".
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func smallButton(title: String, action: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.handler = action
        return button
    }

    static func tint(for kind: AttentionKind) -> NSColor {
        switch kind {
        case .approval: return .systemRed
        case .question: return .systemPurple
        case .handoff: return .systemPurple
        case .stageDecision: return .systemBlue
        case .workComplete: return .systemGreen
        case .idle: return .systemGray
        case .error: return .systemOrange
        case .suspectedStall: return .systemGray
        }
    }

    static func ageString(from: Date, to: Date) -> String {
        let seconds = max(0, Int(to.timeIntervalSince(from)))
        if seconds < 45 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}

extension ClosureButton {
    @objc func fireMenuLink(_ sender: NSMenuItem) {
        guard let identity = sender.representedObject as? SessionIdentity else { return }
        linkHandler?(identity)
    }

    @objc func fireMenuContext(_ sender: NSMenuItem) {
        guard let identity = sender.representedObject as? SessionIdentity else { return }
        contextHandler?(identity)
    }

    @objc func fireMenuItemAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? AttentionItem else { return }
        itemHandler?(item)
    }

    @objc func fireMenuSecondaryAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? AttentionItem else { return }
        secondaryItemHandler?(item)
    }

    @objc func fireMenuCopy(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Inspection hooks

/// Read-only access to what the panel actually built, used by `AgentWarden --uicheck`.
extension AttentionPanelController {
    var debugFrame: NSRect { panel.frame }
    var debugIsVisible: Bool { panel.isVisible }
    var debugWindowAcceptsMouseMoved: Bool { panel.acceptsMouseMovedEvents }
    var debugWindowCanBecomeKey: Bool { panel.canBecomeKey }
    var debugContentView: NSView? { panel.contentView }
    var debugAppearanceName: NSAppearance.Name? { panel.appearance?.name }

    var debugTextValues: [String] {
        guard let root = panel.contentView else { return [] }
        return AttentionPanelController.collect(in: root) { ($0 as? NSTextField)?.stringValue }
            .filter { !$0.isEmpty }
    }

    var debugAccessibilityLabels: [String] {
        guard let root = panel.contentView else { return [] }
        return AttentionPanelController.collect(in: root) { $0.accessibilityLabel() }
            .filter { !$0.isEmpty }
    }

    var debugButtonTitles: [String] {
        guard let root = panel.contentView else { return [] }
        return AttentionPanelController.buttons(in: root).map(\.title)
    }

    /// Every view that claims to be clickable, for the cursor-policy checks.
    var debugClickTargets: [NSView] {
        guard let root = panel.contentView else { return [] }
        var found: [NSView] = AttentionPanelController.buttons(in: root)
        found += AttentionPanelController.clickableViews(in: root).filter(\.isClickable)
        return found
    }

    var debugLabels: [NSTextField] {
        guard let root = panel.contentView else { return [] }
        return AttentionPanelController.textFields(in: root)
    }

    /// The buttons on one rendered row. In the simplified design there is exactly one: the ⋯ menu.
    func debugRowButtons(index: Int) -> [ClosureButton] {
        guard renderedRows.indices.contains(index) else { return [] }
        return AttentionPanelController.buttons(in: renderedRows[index])
    }

    /// The ⋯ menu one row would show, built exactly as a click builds it.
    func debugRowMenu(index: Int) -> NSMenu? {
        guard let button = debugOverflowButton(index: index) else { return nil }
        return AttentionPanelController.captureMenu(from: button)
    }

    /// The ⋯ button specifically — a row may also carry the chain icon.
    func debugOverflowButton(index: Int) -> ClosureButton? {
        debugRowButtons(index: index).first { $0.title == "•••" }
    }

    /// The chain icon, when the row has one.
    func debugChainButton(index: Int) -> ClosureButton? {
        debugRowButtons(index: index).first { $0.title.isEmpty && $0.image != nil }
    }

    /// The Details submenu of one row's ⋯ menu.
    func debugDetailsMenu(rowIndex: Int) -> NSMenu? {
        debugRowMenu(index: rowIndex)?.items.first { $0.title == "Details" }?.submenu
    }

    /// The settings menu the gear would show.
    func debugSettingsMenu() -> NSMenu { settingsMenu() }

    /// What a screen reader would read out for each row.
    var debugRowAccessibilityLabels: [String] {
        renderedRows.compactMap { $0.accessibilityLabel() }
    }

    /// What clicking each row would do, in the words the tooltip uses.
    var debugRowTooltips: [String] {
        renderedRows.compactMap { $0.toolTip }
    }

    static func captureMenu(from button: ClosureButton) -> NSMenu? {
        var captured: NSMenu?
        let previous = button.menuPresenter
        button.menuPresenter = { captured = $0 }
        button.handler?()
        button.menuPresenter = previous
        return captured
    }

    var debugVersionLabelText: String { versionLabel.stringValue }

    var debugRowCount: Int { renderedRows.count }

    /// Every text field under a view, at any depth. Rows nest their labels in stacks.
    static func allTextFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { child -> [NSTextField] in
            if let label = child as? NSTextField { return [label] }
            return allTextFields(in: child)
        }
    }

    /// Which rendered rows carry the "not read yet" dot. Read from the drawn text, not from the
    /// data that produced it — a check that asks the model what it said proves nothing about the row.
    var debugUnseenMarkedRows: [Int] {
        renderedRows.enumerated().compactMap { index, row in
            AttentionPanelController.allTextFields(in: row)
                .contains { $0.attributedStringValue.string.hasPrefix("● ") } ? index : nil
        }
    }

    /// Labels whose text needs more room than they were given.
    ///
    /// The layout assertions all passed while the subtitle was rendering as "1 awaiti" — a string
    /// is present in `debugTextValues` whether or not any of it is visible. This measures instead:
    /// a wrapping label must have the height its text needs, and a single-line label must either
    /// fit or be explicitly set to truncate.
    var debugClippedLabels: [String] {
        guard let root = panel.contentView else { return [] }
        root.layoutSubtreeIfNeeded()
        return AttentionPanelController.textFields(in: root).compactMap { field in
            guard !field.stringValue.isEmpty, field.frame.width > 1 else { return nil }
            let text = NSAttributedString(
                string: field.stringValue,
                attributes: [.font: field.font ?? NSFont.systemFont(ofSize: 12)]
            )
            if field.maximumNumberOfLines == 1 {
                guard field.lineBreakMode != .byTruncatingTail, field.lineBreakMode != .byTruncatingMiddle else {
                    return nil     // clipping here is the deliberate choice, with an ellipsis to show it
                }
                return text.size().width > field.frame.width + 0.5 ? field.stringValue : nil
            }
            let needed = text.boundingRect(
                with: NSSize(width: field.frame.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
            return needed > field.frame.height + 1 ? field.stringValue : nil
        }
    }

    /// The row itself is the primary action, so this is what a click on the name does.
    func debugClickRow(index: Int) {
        guard renderedRows.indices.contains(index) else { return }
        renderedRows[index].onClick?()
    }

    /// Fires one entry of a row's ⋯ menu by title, through the same target/action the menu uses.
    @discardableResult
    func debugClickRowMenuItem(index: Int, titled title: String) -> Bool {
        guard let menu = debugRowMenu(index: index),
              let item = menu.items.first(where: { $0.title == title }),
              item.isEnabled, let action = item.action, let target = item.target else { return false }
        _ = target.perform(action, with: item)
        return true
    }

    func debugClickPanelButton(titled title: String) {
        guard let root = panel.contentView else { return }
        AttentionPanelController.buttons(in: root).first { $0.title == title }?.handler?()
    }

    /// Symbol buttons carry their meaning in the accessibility label, not the title.
    @discardableResult
    func debugClickPanelButton(labelledWith fragment: String) -> Bool {
        guard let root = panel.contentView else { return false }
        guard let button = AttentionPanelController.buttons(in: root)
            .first(where: { ($0.accessibilityLabel() ?? "").contains(fragment) }) else { return false }
        button.handler?()
        return true
    }

    /// Render the current panel to a PNG. Used to hand a layout to a reviewer; it draws this app's
    /// own view and nothing else on the screen.
    @discardableResult
    func debugWritePNG(to url: URL) -> Bool {
        guard let view = panel.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    static func collect(in view: NSView, _ transform: (NSView) -> String?) -> [String] {
        var found: [String] = []
        if let value = transform(view) { found.append(value) }
        for child in view.subviews { found += collect(in: child, transform) }
        return found
    }

    static func buttons(in view: NSView) -> [ClosureButton] {
        var found: [ClosureButton] = []
        if let button = view as? ClosureButton { found.append(button) }
        for child in view.subviews { found += buttons(in: child) }
        return found
    }

    static func clickableViews(in view: NSView) -> [ClickableView] {
        var found: [ClickableView] = []
        if let clickable = view as? ClickableView { found.append(clickable) }
        for child in view.subviews { found += clickableViews(in: child) }
        return found
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for child in view.subviews { found += textFields(in: child) }
        return found
    }
}
