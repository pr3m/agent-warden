import AppKit
import AgentAttentionCore

/// The circular graphite bubble itself: glyph, badge, drag handling, accessibility.
final class BubbleView: NSView, CursorHosting {
    var wantsPointingHand: Bool { true }

    var onPress: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragged: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Built fresh on every secondary click, so it always reflects the current queue.
    var contextMenuProvider: (() -> NSMenu?)?

    private let glyph = NSImageView()
    private let badge = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")

    /// Stated in sRGB rather than taken from `systemOrange`, which is a dynamic colour: it
    /// resolves differently in Light and Dark, and a badge whose contrast depends on a system
    /// preference is a badge whose contrast is not decided here.
    static let badgeColor = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.13, alpha: 1.0)
    static let badgeTextColor = NSColor(srgbRed: 0.12, green: 0.08, blue: 0.0, alpha: 1.0)
    private var dragOrigin: NSPoint?
    private var didDrag = false
    private var pressPending = false
    var hovering = false

    private(set) var pendingCount = 0
    private(set) var isExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        build()
    }

    private func build() {
        layer?.masksToBounds = false

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .white
        addSubview(glyph)

        badge.wantsLayer = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer?.backgroundColor = BubbleView.badgeColor.cgColor
        badge.layer?.borderWidth = 1.5
        badge.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        addSubview(badge)

        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        // Dark on amber, not white on amber. White over this orange measures 2.1 : 1, which is
        // under the floor for a control — and the badge is the one thing on the bubble that has to
        // be readable at a glance from across a desk.
        badgeLabel.textColor = BubbleView.badgeTextColor
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.44),
            glyph.heightAnchor.constraint(equalTo: widthAnchor, multiplier: 0.44),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            badge.heightAnchor.constraint(equalToConstant: 20),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),

            badgeLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualTo: badgeLabel.widthAnchor, constant: 10),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(pendingCount: 0, expanded: false)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        badge.layer?.cornerRadius = badge.bounds.height / 2
        applyAppearance()
    }

    /// Graphite, so it reads as a control rather than a notification, with the accent reserved for
    /// "something is actually waiting".
    private func applyAppearance() {
        // Opaque, in sRGB. At 0.94 alpha the disc took a tint from whatever was behind it, so a
        // white page lifted the graphite and the badge and glyph lost contrast against their own
        // background. What is drawn on the bubble has to be legible because of the bubble.
        let base = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1.0)
        let lifted = NSColor(srgbRed: 0.26, green: 0.26, blue: 0.26, alpha: 1.0)
        layer?.backgroundColor = (hovering || isExpanded ? lifted : base).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (pendingCount > 0
            ? NSColor.systemOrange.withAlphaComponent(0.7)
            : NSColor.white.withAlphaComponent(0.18)).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    func update(pendingCount: Int, expanded: Bool) {
        self.pendingCount = pendingCount
        self.isExpanded = expanded

        // A shield, not a bell: this is a watch that is always on, not a notification that fired.
        let symbol = pendingCount > 0 ? "shield.lefthalf.filled" : "shield"
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "shield", accessibilityDescription: nil)
        glyph.alphaValue = pendingCount > 0 ? 1.0 : 0.75

        badge.isHidden = pendingCount == 0
        badgeLabel.stringValue = pendingCount > 99 ? "99+" : "\(pendingCount)"

        // Spoken by VoiceOver, and shown on hover. "No sessions need you" would be a claim we
        // cannot make — a session can be uncertain or not yet reporting. This says only what the
        // badge actually counts.
        let summary = pendingCount == 0
            ? "Agent Warden. No confirmed requests."
            : "Agent Warden. \(pendingCount) session\(pendingCount == 1 ? "" : "s") waiting."
        setAccessibilityLabel(summary)
        setAccessibilityValue("\(pendingCount)")
        setAccessibilityHelp(expanded
            ? "Press to hide the session list. Drag to move. Placement can also be set from the menu bar item."
            : "Press to show waiting sessions and session status. Drag to move. Placement can also be set from the menu bar item.")
        toolTip = summary + (expanded ? " Click to collapse." : " Click to open.")
        applyAppearance()
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: ClickCursor.trackingOptions, owner: self))
    }

    /// The glyph and the badge are decoration drawn on top of one control. Without this they would
    /// hit-test as themselves — the badge label would offer a text cursor and eat the click that was
    /// meant to open the panel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func cursorUpdate(with event: NSEvent) {
        hovering = true
        ClickCursor.apply(enabled: wantsPointingHand)
    }

    /// Arriving from a terminal or an editor means arriving with an I-beam. Claim the cursor here:
    /// this is the message a non-activating panel actually receives.
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        ClickCursor.apply(enabled: wantsPointingHand, from: self, event: "entered")
        applyAppearance()
    }

    override func mouseMoved(with event: NSEvent) {
        hovering = true
        ClickCursor.apply(enabled: wantsPointingHand, from: self, event: "moved")
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        // Dragging past the edge of the bubble still ends over the desktop; hand the arrow back.
        ClickCursor.release()
        applyAppearance()
    }

    /// Turning the bubble off from the menu hides it without the pointer moving.
    override func viewDidHide() {
        super.viewDidHide()
        releaseCursorOnDisappear()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { releaseCursorOnDisappear() }
    }

    /// What a press on the bubble should do.
    ///
    /// The two are mutually exclusive on purpose: opening the menu must not also toggle the panel
    /// or begin a drag, which is the usual way a hand-rolled context menu goes wrong.
    enum Press: Equatable {
        case beginClickOrDrag
        case openMenu
    }

    /// The routing rule, separated from AppKit so it can be exercised directly.
    ///
    /// Button 0 is the left button; anything else is a secondary click. Control-left-click is the
    /// long-standing macOS equivalent of a right-click and gets the same treatment — AppKit does
    /// not translate it for a plain `NSView`, so it is handled here.
    static func route(button: Int, modifiers: NSEvent.ModifierFlags) -> Press {
        guard button == 0 else { return .openMenu }
        return modifiers.contains(.control) ? .openMenu : .beginClickOrDrag
    }

    override func mouseDown(with event: NSEvent) {
        switch BubbleView.route(button: event.buttonNumber, modifiers: event.modifierFlags) {
        case .openMenu: presentMenu(with: event)
        case .beginClickOrDrag: beginClickOrDrag()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        presentMenu(with: event)
    }

    /// Right-click is also what AppKit asks a view for when it wants a contextual menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    func beginClickOrDrag(at point: NSPoint = NSEvent.mouseLocation) {
        dragOrigin = point
        didDrag = false
        pressPending = true
    }

    /// The drag rule, with the pointer position passed in rather than read from AppKit.
    func handleDrag(to point: NSPoint) {
        guard let origin = dragOrigin else { return }
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        // A few points of slop, so a slightly shaky click is still a click.
        if !didDrag && (abs(dx) > 3 || abs(dy) > 3) {
            didDrag = true
            onDragBegan?()
        }
        guard didDrag else { return }
        onDragged?(CGPoint(x: dx, y: dy))
    }

    /// The release rule, with no event to inspect.
    func finishPress() {
        defer { dragOrigin = nil; pressPending = false }
        guard pressPending else { return }
        if didDrag { onDragEnded?() } else { onPress?() }
    }

    /// Opens the menu and cancels any click or drag that was starting.
    ///
    /// `showing: false` runs everything except the modal tracking loop, so the routing can be
    /// exercised without a window server.
    func presentMenu(with event: NSEvent?, showing: Bool = true) {
        dragOrigin = nil
        didDrag = false
        pressPending = false      // the release that follows is the menu's, not a click
        NSCursor.arrow.set()
        guard showing, let menu = contextMenuProvider?() else { return }
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.minY), in: self)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        handleDrag(to: NSEvent.mouseLocation)
    }

    /// A release that belongs to a context menu is not a click — `finishPress` checks that.
    /// Without it, control-clicking would open the menu *and* toggle the panel behind it.
    override func mouseUp(with event: NSEvent) {
        finishPress()
    }

    // MARK: - Accessibility

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func isAccessibilityEnabled() -> Bool { true }
}

/// The always-visible floating control.
///
/// It stays on screen whether or not anything is waiting — that is the point of it: a glance tells
/// you the sessions are being watched, not just that something is wrong. It never takes key focus,
/// so it cannot interrupt typing, and it can be dragged anywhere and remembers where it was put.
///
/// We make no attempt to detect other apps' floating controls. That would need window-list access
/// we are not asking for, and a promise we could not keep. The default sits clear of the very
/// corner, and dragging or the menu handles the rest.
final class BubbleController {
    var onToggle: (() -> Void)?
    var onPlacementChanged: ((BubblePlacement) -> Void)?
    /// Supplies the right-click / control-click menu. The bubble is the only thing always on
    /// screen, so it has to be able to quit the app on its own.
    var contextMenuProvider: (() -> NSMenu?)? {
        get { view.contextMenuProvider }
        set { view.contextMenuProvider = newValue }
    }
    /// Observed by `--uicheck` to prove that opening the menu never begins a drag.
    var onDragBegan: (() -> Void)? {
        get { extraDragObserver }
        set { extraDragObserver = newValue }
    }
    private var extraDragObserver: (() -> Void)?

    private let panel: NSPanel
    private let view: BubbleView
    private var size: CGFloat
    private var dragStartFrame: NSRect?

    init(size: CGFloat = 56) {
        self.size = size
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered,
                        defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false          // only so the disc can be round and cast a shadow
        panel.backgroundColor = .clear
        // Pinned, so a system switch to Light cannot resolve anything drawn here into dark-on-dark.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false          // the layer draws its own, so the circle is not boxed
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityLabel("Agent Warden")

        view = BubbleView(frame: rect)
        panel.contentView = view
        // Without this the panel receives no movement at all, and the pointer could only ever be
        // corrected at the moment of entry.
        ClickCursor.prepare(panel)

        view.onPress = { [weak self] in self?.onToggle?() }
        view.onDragBegan = { [weak self] in
            self?.dragStartFrame = self?.panel.frame
            self?.extraDragObserver?()
        }
        view.onDragged = { [weak self] delta in
            guard let self, let start = self.dragStartFrame else { return }
            let moved = NSRect(x: start.minX + delta.x, y: start.minY + delta.y,
                               width: start.width, height: start.height)
            self.panel.setFrameOrigin(BubbleGeometry.clamp(moved, in: self.visibleFrame).origin)
        }
        view.onDragEnded = { [weak self] in
            guard let self else { return }
            self.dragStartFrame = nil
            self.onPlacementChanged?(BubbleGeometry.placement(for: self.panel.frame, in: self.visibleFrame))
        }
    }

    var visibleFrame: CGRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    var frame: NSRect { panel.frame }

    /// For the readability check: the disc as drawn, and the appearance it is pinned to.
    var debugContentView: NSView? { panel.contentView }
    var debugAppearanceName: NSAppearance.Name? { panel.appearance?.name }

    var isVisible: Bool { panel.isVisible }
    var accessibilityLabel: String { view.accessibilityLabel() ?? "" }
    var badgeIsHidden: Bool { view.pendingCount == 0 }

    func apply(placement: BubblePlacement, size: CGFloat) {
        self.size = size
        let target = BubbleGeometry.frame(for: placement,
                                          size: CGSize(width: size, height: size),
                                          in: visibleFrame)
        panel.setFrame(target, display: true)
        view.frame = NSRect(origin: .zero, size: target.size)
        view.needsLayout = true
    }

    func update(pendingCount: Int, expanded: Bool) {
        view.update(pendingCount: pendingCount, expanded: expanded)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Re-clamp after a display change, keeping the remembered corner.
    func reposition(placement: BubblePlacement) {
        apply(placement: placement, size: size)
    }

    // Used by `--uicheck`.

    /// The centre of the bubble sits over the glyph; a click there must still be the bubble's.
    var debugHitTestCentreIsWholeBubble: Bool {
        view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)) === view
    }

    /// The badge corner is the other place decoration could swallow a click.
    var debugHitTestOverBadgeIsWholeBubble: Bool {
        view.layoutSubtreeIfNeeded()
        let point = NSPoint(x: view.bounds.maxX - 10, y: view.bounds.maxY - 10)
        return view.hitTest(point) === view
    }

    var debugTrackingCoversCursor: Bool {
        view.updateTrackingAreas()
        return view.trackingAreas.contains {
            $0.options.contains(.mouseEnteredAndExited)
            && $0.options.contains(.mouseMoved)
            && $0.options.contains(.activeAlways)
        }
    }

    /// The routing decision itself, for a given button and modifier combination.
    func debugRoute(button: Int, modifiers: NSEvent.ModifierFlags = []) -> BubbleView.Press {
        BubbleView.route(button: button, modifiers: modifiers)
    }

    /// Drive the real press path without a window server: down, optional drag, then release.
    ///
    /// It runs the same routing, drag-slop and release rules the AppKit handlers run — the only
    /// thing left out is `NSMenu.popUpContextMenu`, which needs a modal tracking loop. The menu it
    /// would have shown is returned instead, so a test can inspect what is on it.
    @discardableResult
    func debugPressSequence(
        button: Int,
        modifiers: NSEvent.ModifierFlags = [],
        dragBy delta: CGPoint? = nil
    ) -> NSMenu? {
        let origin = NSPoint(x: 500, y: 500)
        var menu: NSMenu?
        switch BubbleView.route(button: button, modifiers: modifiers) {
        case .openMenu:
            menu = view.contextMenuProvider?()
            view.presentMenu(with: nil, showing: false)
        case .beginClickOrDrag:
            view.beginClickOrDrag(at: origin)
            if let delta {
                view.handleDrag(to: NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
            }
        }
        view.finishPress()
        return menu
    }

    func debugPress() { view.onPress?() }
    /// The bubble's own view, so a check can drive the entry and movement events AppKit delivers.
    var debugView: BubbleView { view }
    var debugWindowAcceptsMouseMoved: Bool { panel.acceptsMouseMovedEvents }
    var debugWindowCanBecomeKey: Bool { panel.canBecomeKey }
    func debugDrag(by delta: CGPoint) {
        view.onDragBegan?()
        view.onDragged?(delta)
        view.onDragEnded?()
    }
}
