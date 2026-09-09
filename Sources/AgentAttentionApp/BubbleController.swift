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

    /// The graphite circle itself — everything the user thinks of as "the bubble".
    ///
    /// A child view rather than this view's own layer, because the window is deliberately larger
    /// than the circle: `BubbleGeometry.haloInset` points of transparent margin on every side, so
    /// the roam halo has somewhere to be drawn that the window will not clip. Painting the disc on
    /// the root layer would make the disc grow with the window instead of leaving that margin.
    private let disc = NSView()
    /// The roam ring, stroked in the margin between the disc's edge and the window's.
    ///
    /// A layer, not a view: it has no hit-testing, no layout and no subviews of its own, and
    /// `CAShapeLayer` strokes a circle without needing a `draw(_:)` override. Kept separate from
    /// the disc's border on purpose — see `applyAppearance`.
    private let halo = CAShapeLayer()
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
    private(set) var unseenCount = 0
    private(set) var isExpanded = false
    private(set) var isRoaming = false
    private let totalLabel = NSTextField(labelWithString: "")

    // Read back from the views themselves, for checks.
    var badgeIsHidden: Bool { badge.isHidden }
    var badgeText: String { badgeLabel.stringValue }
    var totalIsHidden: Bool { totalLabel.isHidden }
    var totalText: String { totalLabel.stringValue }
    /// Whether the halo is actually painting, read back off the layer rather than off the flag
    /// that was passed in: a check that asks the caller what it said proves nothing about what is
    /// on screen.
    var haloIsPainted: Bool { (halo.strokeColor?.alpha ?? 0) > 0 }

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
        // This view is now only a frame around the disc: the whole of it that is not the disc is
        // the halo margin, and none of it may paint. Stated rather than left to the defaults,
        // because the disc's background, radius and border used to live here.
        //
        // There is no `masksToBounds = false` any more. It mattered when this view *was* the disc
        // and carried the circle's corner radius — it was what stopped the badge being clipped to
        // the circle. That guard moved to `disc.layer` below, where the badge now is. Here it
        // could not do anything either way: this view is the window's content view, so its layer's
        // bounds and the window's clipping rectangle are the same rectangle, and masking to them
        // cannot remove a pixel the window would have drawn.
        layer?.backgroundColor = nil
        layer?.borderWidth = 0
        layer?.cornerRadius = 0

        // Beneath everything, including the disc. The two only meet at the disc's edge, so this
        // decides nothing more than which of the two owns that single shared boundary pixel.
        halo.fillColor = NSColor.clear.cgColor
        layer?.insertSublayer(halo, at: 0)

        disc.wantsLayer = true
        disc.translatesAutoresizingMaskIntoConstraints = false
        // The badge overhangs the circle at the corner of the disc's square bounds, exactly as it
        // did when the disc was this view; clipping it to the disc would crop it.
        disc.layer?.masksToBounds = false
        addSubview(disc)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .white
        disc.addSubview(glyph)

        badge.wantsLayer = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer?.backgroundColor = BubbleView.badgeColor.cgColor
        badge.layer?.borderWidth = 1.5
        badge.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        disc.addSubview(badge)

        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        // Dark on amber, not white on amber. White over this orange measures 2.1 : 1, which is
        // under the floor for a control — and the badge is the one thing on the bubble that has to
        // be readable at a glance from across a desk.
        // The quiet one: how much is still waiting, whether or not any of it is new. Deliberately
        // small, unfilled and low-contrast — it is a backlog, not an alert, and it must not compete
        // with the badge for the eye.
        totalLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        totalLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        totalLabel.isBezeled = false
        totalLabel.isEditable = false
        totalLabel.drawsBackground = false
        totalLabel.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(totalLabel)

        badgeLabel.textColor = BubbleView.badgeTextColor
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeLabel)

        let inset = BubbleGeometry.haloInset
        NSLayoutConstraint.activate([
            // The margin the halo is drawn in. Everything else on the bubble hangs off the disc,
            // not off this view, so growing the window by `inset * 2` moves nothing the user sees.
            disc.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            disc.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            disc.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            disc.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),

            glyph.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            glyph.widthAnchor.constraint(equalTo: disc.widthAnchor, multiplier: 0.44),
            glyph.heightAnchor.constraint(equalTo: disc.widthAnchor, multiplier: 0.44),

            badge.trailingAnchor.constraint(equalTo: disc.trailingAnchor, constant: -2),
            badge.topAnchor.constraint(equalTo: disc.topAnchor, constant: 2),
            badge.heightAnchor.constraint(equalToConstant: 20),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),

            badgeLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualTo: badgeLabel.widthAnchor, constant: 10),

            // Opposite corner from the badge on purpose: the two numbers answer different questions
            // and must never be mistaken for each other at a glance.
            totalLabel.leadingAnchor.constraint(equalTo: disc.leadingAnchor, constant: 7),
            totalLabel.bottomAnchor.constraint(equalTo: disc.bottomAnchor, constant: -6),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(pendingCount: 0, unseenCount: 0, expanded: false, roaming: false)
    }

    override func layout() {
        super.layout()
        // `super.layout()` is what applies the constraint-based frames, so the disc's bounds are
        // only trustworthy after it has run.
        disc.layer?.cornerRadius = disc.bounds.width / 2
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
        disc.layer?.backgroundColor = (hovering || isExpanded ? lifted : base).cgColor
        disc.layer?.borderWidth = 1
        disc.layer?.borderColor = (pendingCount > 0
            ? NSColor.systemOrange.withAlphaComponent(0.7)
            : NSColor.white.withAlphaComponent(0.18)).cgColor

        // Roam gets a channel of its own. The disc's border already means "sessions are waiting",
        // and overloading one surface with two meanings makes both harder to read — so the halo
        // lives in the margin *outside* the disc and the two compose: roaming with three sessions
        // waiting reads as both at once rather than as one overwriting the other. Teal for the
        // same reason: it has to be un-mistakable for the orange the border uses. Like that
        // orange it is a system colour resolved right here, in this method, so whatever appearance
        // is in effect is in effect for both of them.
        //
        // Implicit animation is switched off. This is a layer added by hand, not a view's backing
        // layer, so Core Animation animates `path`, `lineWidth` and `strokeColor` by default — and
        // `applyAppearance` runs on every layout, hover, and update, which would smear the ring
        // across a window resize or a plain re-render.
        let inset = BubbleGeometry.haloInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.frame = bounds
        // Stroked down the centre line of a circle inset by half the margin, so a `lineWidth` of
        // `inset` covers exactly the margin: from the disc's edge out to the window's, and no
        // further — anything further would be clipped by the window, which is the whole reason
        // the window is `inset` points bigger than the disc in the first place.
        halo.path = CGPath(ellipseIn: bounds.insetBy(dx: inset / 2, dy: inset / 2), transform: nil)
        halo.lineWidth = inset
        // Slightly under solid: the ring's outer edge is flush with the window's, where the
        // window's own drop shadow begins, and it is decoration with nothing drawn on it — no text
        // is measured against it, so no contrast floor applies.
        //
        // Painting this ring is also what makes the margin swallow clicks while roaming, because
        // the WindowServer routes a mouse-down by rendered alpha. Widening or solidifying it
        // widens that dead zone — see `hitTest` for why nothing here can hand the click on.
        halo.strokeColor = isRoaming
            ? NSColor.systemTeal.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()

        // **No layer shadow here, on purpose.** This view *is* the window's content view, and the
        // window is only `BubbleGeometry.haloInset` points bigger than the disc on each side. A
        // shadow drawn by any layer in here is therefore clipped to the window rectangle: it
        // cannot spread out to the distance a drop shadow needs, so all that renders is the
        // shadow filling the corners around the circle — a grey square with a hole in the middle,
        // which is precisely what it looked like. Giving it a circular `shadowPath` does not help,
        // because the clipping is the window, not the path. The shadow is cast by the *window*
        // instead (`hasShadow`), which is not clipped and follows the content's own alpha — which
        // is why this call matters here: turning the halo on or off changes that alpha's outline,
        // and the window's cached shadow has to be told.
        window?.invalidateShadow()
    }

    /// - Parameter unseenCount: how many of `pendingCount` the user has not looked at yet. The badge
    ///   counts these; the quiet corner number counts everything still waiting. A queue that is all
    ///   old shows no badge at all, which is the point: the badge means *new*, and a badge that is
    ///   permanently lit is a badge nobody reads.
    /// - Parameter roaming: whether roam mode is currently holding the machine awake. Shown as the
    ///   halo, in the margin outside the disc, and said in the label — never on the disc's border,
    ///   which already carries the "sessions are waiting" signal.
    func update(pendingCount: Int, unseenCount: Int, expanded: Bool, roaming: Bool) {
        self.pendingCount = pendingCount
        self.unseenCount = min(max(0, unseenCount), pendingCount)
        self.isExpanded = expanded
        self.isRoaming = roaming

        // A shield, not a bell: this is a watch that is always on, not a notification that fired.
        let symbol = pendingCount > 0 ? "shield.lefthalf.filled" : "shield"
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "shield", accessibilityDescription: nil)
        glyph.alphaValue = pendingCount > 0 ? 1.0 : 0.75

        badge.isHidden = self.unseenCount == 0
        badgeLabel.stringValue = self.unseenCount > 99 ? "99+" : "\(self.unseenCount)"
        // Shown only when it says something the badge does not: either nothing is new, or not
        // everything waiting is new. Two identical numbers on one bubble is noise.
        totalLabel.isHidden = pendingCount == 0 || pendingCount == self.unseenCount
        totalLabel.stringValue = pendingCount > 99 ? "99+" : "\(pendingCount)"

        // Spoken by VoiceOver, and shown on hover. "No sessions need you" would be a claim we
        // cannot make — a session can be uncertain or not yet reporting. This says only what the
        // badge actually counts.
        let waiting = "\(pendingCount) session\(pendingCount == 1 ? "" : "s") waiting"
        let summary: String
        if pendingCount == 0 {
            summary = "Agent Warden. No confirmed requests."
        } else if self.unseenCount == 0 {
            summary = "Agent Warden. \(waiting), none new since you looked."
        } else if self.unseenCount == pendingCount {
            summary = "Agent Warden. \(waiting), all new."
        } else {
            summary = "Agent Warden. \(waiting), \(self.unseenCount) new."
        }
        // Said, not only drawn. The halo is a colour in a 4pt margin: it is the one thing on this
        // bubble that a person who cannot see it has no other way of learning.
        let roamNote = roaming ? " Roam is on." : ""
        setAccessibilityLabel(summary + roamNote)
        setAccessibilityValue("\(pendingCount)")
        setAccessibilityHelp(expanded
            ? "Press to hide the session list. Drag to move. Placement can also be set from the menu bar item."
            : "Press to show waiting sessions and session status. Drag to move. Placement can also be set from the menu bar item.")
        toolTip = summary + roamNote + (expanded ? " Click to collapse." : " Click to open.")
        applyAppearance()
    }

    // MARK: - Mouse

    /// Tracked over the disc, not over the whole view: the halo margin is not part of the control,
    /// so it must not show the pointing hand or lift the disc on hover. Derived from this view's
    /// own bounds rather than read off `disc.frame` so it is right even before the first layout
    /// pass — and, at `haloInset` points in on every side, it is the disc's rect by construction.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let discRect = bounds.insetBy(dx: BubbleGeometry.haloInset, dy: BubbleGeometry.haloInset)
        addTrackingArea(NSTrackingArea(rect: discRect, options: ClickCursor.trackingOptions, owner: self))
    }

    /// The glyph and the badge are decoration drawn on top of one control. Without this they would
    /// hit-test as themselves — the badge label would offer a text cursor and eat the click that was
    /// meant to open the panel.
    ///
    /// The **halo margin** is decoration too, and must not hit-test at all: a click a few points
    /// outside the disc must not be read as a click on the bubble. The disc's square frame is the
    /// boundary, not its circle, because that square is precisely what this view's bounds used to
    /// be — the corners were clickable then and stay so.
    ///
    /// **A known trade-off, accepted.** Returning `nil` here is not the same as passing the click
    /// on. The WindowServer decides which *window* gets a mouse-down from window order plus, for a
    /// non-opaque window, the rendered alpha at that point — and it decides that before AppKit ever
    /// calls `hitTest`. So while roam is **off** the margin is fully transparent and the click
    /// really does reach whatever is behind, exactly as the square window's corners always have.
    /// While roam is **on** the ring is painted, the click is already committed to this window, and
    /// all this method can do is refuse it: no drag, no toggle, and nothing for the app underneath
    /// either. A click in that 4pt ring while roaming therefore does nothing at all.
    ///
    /// Nothing here can change that — `NSWindow.ignoresMouseEvents` is window-wide, not regional.
    /// Eliminating it would take a second, decorative window carrying the ring with
    /// `ignoresMouseEvents = true`, which was judged more machinery than a 4pt ring is worth.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard disc.frame.contains(local) else { return nil }
        return super.hitTest(point) == nil ? nil : self
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
    /// The **disc's** diameter, as configured. Never the window's — see `windowSide(forDisc:)`.
    private var size: CGFloat
    private var dragStartFrame: NSRect?

    /// The window is the disc plus a halo margin on every side.
    ///
    /// The margin is unconditional, not added only while roaming: resizing the window on every
    /// roam toggle would mean recomputing the placement and the bubble visibly jumping each time
    /// the flag flipped. 8pt of permanently transparent window buys a toggle that never moves it.
    private static func windowSide(forDisc size: CGFloat) -> CGFloat {
        size + BubbleGeometry.haloInset * 2
    }

    /// - Parameter size: the diameter of the **disc**, which is what the user configures and what
    ///   they see. The window is `BubbleGeometry.haloInset * 2` larger, so the halo has a margin
    ///   to be drawn in without the disc shrinking to pay for it.
    init(size: CGFloat = 56) {
        self.size = size
        let rect = NSRect(x: 0, y: 0, width: BubbleController.windowSide(forDisc: size),
                          height: BubbleController.windowSide(forDisc: size))
        // `.utilityWindow` is deliberately absent. It is a *titled-panel* trait, and on a borderless
        // panel AppKit still draws the utility background behind the content — which showed up as a
        // soft grey square sitting behind the disc, exactly the thing a round, transparent bubble is
        // not supposed to have. `.nonactivatingPanel` is what actually earns its place here: it is
        // what lets the bubble be clicked without taking focus from the terminal.
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
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
        // The window casts the shadow, not the disc's layer. A layer shadow would be clipped to this
        // window's bounds — and the window clears the disc by only a few points of halo margin, far
        // less than a drop shadow needs, so that clipped shadow showed up as a grey square around
        // the circle. A window shadow is drawn outside the window and follows the alpha of what is
        // in it, so a round bubble casts a round shadow.
        panel.hasShadow = true
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
            // `haloInset:` is what stops the bubble creeping. `panel.frame` is the window, which is
            // wider than the disc by the margin; without trimming it back, every drag would remember
            // an offset 4pt larger than the disc's real one and the bubble would walk away from its
            // corner a little more each time it was moved.
            self.onPlacementChanged?(BubbleGeometry.placement(for: self.panel.frame,
                                                              in: self.visibleFrame,
                                                              haloInset: BubbleGeometry.haloInset))
        }
    }

    var visibleFrame: CGRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// The bubble's **window**, halo margin included. This is what the expanded panel anchors to,
    /// which is why `AttentionPanelController.layoutAndPosition` passes `haloInset:` when it
    /// resolves the panel's position from it.
    var frame: NSRect { panel.frame }

    /// The **disc** as drawn: the window minus its halo margin. This is the circle the user placed
    /// and the circle they measure by eye, so it is what a check about size or position should ask
    /// for. `frame` is 8pt wider in each axis and mostly transparent.
    var discFrame: NSRect { panel.frame.insetBy(dx: BubbleGeometry.haloInset,
                                                dy: BubbleGeometry.haloInset) }

    /// For the readability check: the disc as drawn, and the appearance it is pinned to.
    var debugContentView: NSView? { panel.contentView }
    var debugAppearanceName: NSAppearance.Name? { panel.appearance?.name }

    var isVisible: Bool { panel.isVisible }
    var accessibilityLabel: String { view.accessibilityLabel() ?? "" }
    /// Reads the real views, not the numbers that were passed in — a check that asks the caller
    /// what it said proves nothing about what is on screen.
    var badgeIsHidden: Bool { view.badgeIsHidden }
    var badgeText: String { view.badgeText }
    var totalText: String { view.totalIsHidden ? "" : view.totalText }

    /// - Parameter size: the disc's diameter, as configured. The window resolved here is that plus
    ///   the halo margin, and `haloInset:` is what tells `BubbleGeometry` that the remembered
    ///   offset measures to the disc's edge rather than the window's — without it the bubble would
    ///   land 4pt inside where the user left it.
    func apply(placement: BubblePlacement, size: CGFloat) {
        self.size = size
        let side = BubbleController.windowSide(forDisc: size)
        let target = BubbleGeometry.frame(for: placement,
                                          size: CGSize(width: side, height: side),
                                          in: visibleFrame,
                                          haloInset: BubbleGeometry.haloInset)
        panel.setFrame(target, display: true)
        view.frame = NSRect(origin: .zero, size: target.size)
        view.needsLayout = true
    }

    func update(pendingCount: Int, unseenCount: Int, expanded: Bool, roaming: Bool) {
        view.update(pendingCount: pendingCount, unseenCount: unseenCount,
                    expanded: expanded, roaming: roaming)
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
    ///
    /// Laid out first: `hitTest` now consults the disc's frame, which the constraint solver has
    /// not filled in until a layout pass has run.
    var debugHitTestCentreIsWholeBubble: Bool {
        view.layoutSubtreeIfNeeded()
        return view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)) === view
    }

    /// The badge corner is the other place decoration could swallow a click.
    var debugHitTestOverBadgeIsWholeBubble: Bool {
        view.layoutSubtreeIfNeeded()
        let point = NSPoint(x: view.bounds.maxX - 10, y: view.bounds.maxY - 10)
        return view.hitTest(point) === view
    }

    /// The halo margin is decoration, and a click in it must not be the bubble's — otherwise the
    /// window's 4pt growth would silently make a ring of dead space clickable and draggable.
    /// Sampled at the middle of each edge, which is where the margin is at its thinnest.
    var debugHitTestInHaloMarginIsNothing: Bool {
        view.layoutSubtreeIfNeeded()
        let half = BubbleGeometry.haloInset / 2
        let points = [NSPoint(x: view.bounds.midX, y: view.bounds.minY + half),
                      NSPoint(x: view.bounds.midX, y: view.bounds.maxY - half),
                      NSPoint(x: view.bounds.minX + half, y: view.bounds.midY),
                      NSPoint(x: view.bounds.maxX - half, y: view.bounds.midY)]
        return points.allSatisfy { view.hitTest($0) == nil }
    }

    /// Whether the roam ring is actually stroking anything, read back off the layer.
    var debugHaloIsPainted: Bool { view.haloIsPainted }

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
