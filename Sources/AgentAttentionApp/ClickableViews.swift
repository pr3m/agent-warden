import AppKit
import AgentAttentionCore

/// The cursor policy, in one place.
///
/// The bubble and the panel are borderless, non-activating windows. They get no cursor management
/// for free, so the pointer keeps whatever shape the window underneath last set — walk off a
/// terminal and onto the bubble and you are still holding an I-beam over something you can click.
///
/// Four rules:
/// - anything clickable and enabled sets `pointingHand` while the pointer is over it;
/// - a disabled control does not, because it would be claiming something untrue;
/// - the cursor is only ever `set`, never pushed. There is no stack to leave unbalanced;
/// - every view releases the cursor explicitly when it stops being a target, and only while the
///   pointer is actually inside it — never globally, never on behalf of another control.
///
/// **Where the first attempt went wrong.** It hung the whole policy on `cursorUpdate(with:)`.
/// AppKit does not send that message for a tracking area registered with `.activeAlways`, which is
/// every area in this app, because the bubble and the panel are deliberately never key. So walking
/// off a terminal and onto the bubble delivered `mouseEntered` — which only recorded that the
/// pointer had arrived — and nothing ever called `set`. The I-beam stayed, exactly as reported.
///
/// What a background window *does* receive is enter, exit, and — once the window asks for them —
/// movement. Those are what the cursor is set from. The suppression is a property of the option,
/// not of which window is key, so there is no arrangement in this app where `cursorUpdate` would
/// arrive: the option is gone, and the overrides that remain are a correct answer to a message that
/// is not sent here rather than part of the mechanism.
enum ClickCursor {
    static func apply(enabled: Bool) {
        (enabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// The same, with a diagnostic line when diagnostics are switched on.
    static func apply(enabled: Bool, from view: NSView, event kind: String) {
        let wanted = enabled ? NSCursor.pointingHand : NSCursor.arrow
        wanted.set()
        // A measurement taken in the same breath as the change can precede the compositor. Entry
        // gets one delayed second look; movement does not, because movement repeats anyway.
        CursorDiagnostics.record(kind, view, wanted: wanted, delayedSample: kind == "entered")
    }

    /// Hand the pointer back. Only ever called by a view that knows the pointer is over it.
    static func release() {
        NSCursor.arrow.set()
    }

    /// Tracking options for a control inside a window that never becomes key.
    ///
    /// `.activeAlways` is what makes anything arrive at all while another application is in front —
    /// and it is also why `.cursorUpdate` is **not** in this list. Apple's rule is about the option,
    /// not about which window is key: an area registered `.activeAlways` is never sent
    /// `cursorUpdate(with:)`. Leaving it in would suggest a second mechanism that does not exist.
    /// Enter, exit and movement are delivered, and they are the whole policy.
    static let trackingOptions: NSTrackingArea.Options = [
        .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect,
    ]

    /// Every window holding views that use this policy has to be told to deliver movement.
    ///
    /// Without it the pointer can only be corrected at the moment it enters — and any other
    /// application that reasserts its own cursor afterwards keeps it. This applies to the ordinary
    /// windows too, not only the borderless ones: their buttons are the same shared controls.
    static func prepare(_ window: NSWindow) {
        window.acceptsMouseMovedEvents = true
    }
}

/// Opt-in, bounded diagnostics for the cursor question — off unless asked for, and finite when on.
///
/// It exists because the thing that needs proving cannot be proved from inside a test. AppKit's own
/// header says `NSCursor.currentCursor` "isn't necessarily the cursor that is currently being
/// displayed, as the system may be showing the cursor for another running application". So a run
/// where a person actually hovers over Agent Warden is the only evidence that counts.
///
/// **Bounds, because "diagnostic" is not a licence to write for ever.** A run stops at whichever
/// comes first: 400 records, 64 KiB, or ten minutes from the first line. After that it writes
/// nothing until the app is restarted. There is no timer and no polling — every line is produced by
/// a hover event on one of Agent Warden's own views, so with the pointer elsewhere it is silent.
///
/// **What it records:** time, event kind, the view's type, whether this app is active, whether its
/// window is key, and a *fingerprint* of two cursors — the one this app set and the one the system
/// reports — as size, hot spot and a cheap hash of the image bits. Comparing singletons with `==`
/// gives false negatives for visually identical cursors, which is exactly the mistake that would
/// send this investigation in the wrong direction again. Nil is recorded as `unknown`, never as a
/// match or a mismatch.
///
/// **What it never records:** screen contents, keystrokes, transcripts, session text, anything from
/// another application, and no image is ever written to disk — only a hash of one.
///
/// The file is created 0600 in the data directory.
enum CursorDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["AGENT_WARDEN_CURSOR_DIAGNOSTICS"] == "1"

    static let maximumRecords = 400
    static let maximumBytes = 64 * 1024
    static let maximumDuration: TimeInterval = 600

    private static let lock = NSLock()
    private static var records = 0
    private static var bytes = 0
    private static var startedAt: Date?
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// One line for the event itself, and — only for an entry — one bounded sample a moment later.
    ///
    /// The second sample exists to tell two very different explanations apart: a cursor that is
    /// applied late by the compositor, and one that never takes at all. It is a single delayed read,
    /// not a loop; it is discarded if the pointer has since left or the view moved on.
    static func record(_ kind: String, _ view: NSView, wanted: NSCursor, delayedSample: Bool = false) {
        guard isEnabled else { return }
        write(line(kind, view, wanted: wanted))
        guard delayedSample, let host = view as? any CursorHosting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak view] in
            guard let view, host.hovering, view.window != nil else { return }   // hover ended: drop it
            write(line("\(kind)+250ms", view, wanted: wanted))
        }
    }

    private static func line(_ kind: String, _ view: NSView, wanted: NSCursor) -> String {
        let system = NSCursor.currentSystem
        return [
            stamp.string(from: Date()),
            kind,
            String(describing: type(of: view)),
            "appActive=\(NSApp?.isActive == true)",
            "windowKey=\(view.window?.isKeyWindow == true)",
            "windowCanBecomeKey=\(view.window?.canBecomeKey == true)",
            "wanted=\(fingerprint(wanted))",
            "appLocal=\(fingerprint(NSCursor.current))",
            "system=\(fingerprint(system))",
            "systemMatchesWanted=\(matches(system, wanted))",
        ].joined(separator: "  ")
    }

    /// Shape, not identity: size, hot spot and a hash of the image's own bits. No image is stored.
    static func fingerprint(_ cursor: NSCursor?) -> String {
        guard let cursor else { return "unknown(nil)" }
        let size = cursor.image.size
        let hot = cursor.hotSpot
        var hash = 0
        if let tiff = cursor.image.tiffRepresentation {
            var hasher = Hasher()
            hasher.combine(tiff)
            hash = hasher.finalize()
        }
        return String(format: "%.0fx%.0f@%.0f,%.0f#%08x", size.width, size.height, hot.x, hot.y,
                      UInt32(truncatingIfNeeded: hash))
    }

    /// `yes`, `no`, or `unknown` when the system reading is unavailable. Never guessed.
    static func matches(_ system: NSCursor?, _ wanted: NSCursor) -> String {
        guard let system else { return "unknown" }
        return fingerprint(system) == fingerprint(wanted) ? "yes" : "no"
    }

    /// Has this run used up its budget? Exposed so a check can assert the bound exists.
    static var isExhausted: Bool {
        lock.lock(); defer { lock.unlock() }
        return exhaustedLocked()
    }

    private static func exhaustedLocked() -> Bool {
        if records >= maximumRecords || bytes >= maximumBytes { return true }
        if let startedAt, Date().timeIntervalSince(startedAt) > maximumDuration { return true }
        return false
    }

    private static func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if startedAt == nil { startedAt = Date() }
        guard !exhaustedLocked() else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        records += 1
        bytes += data.count

        let url = AppPaths.resolved().root.appendingPathComponent("cursor-diagnostics.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // Created private to this user, like every other file this app writes.
            FileManager.default.createFile(atPath: url.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    /// For checks only: forget the budget so a fixture can exercise it.
    static func debugReset() {
        lock.lock(); defer { lock.unlock() }
        records = 0
        bytes = 0
        startedAt = nil
    }
}

/// A window that closes on Escape, and on nothing else.
///
/// Cocoa already routes Escape to `cancelOperation(_:)` down the responder chain when the window is
/// key. This adopts that path rather than inventing one: **no global key monitor, no event tap, no
/// Accessibility grant, and no focus taken to catch a keystroke.** The consequence is worth stating
/// plainly — Escape closes these windows *while you are in Agent Warden*. If you are typing in a
/// terminal, that Escape belongs to the terminal, and Agent Warden neither sees it nor should.
///
/// It closes the window. It never touches the queue: nothing is dismissed, snoozed or resolved, no
/// session is stopped, and an unconfirmed link is not saved.
final class EscapeClosableWindow: NSWindow {
    /// Called instead of the default close, so the owner can invalidate its in-flight work.
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// `NSWindow` only forwards `cancelOperation` when something in the responder chain accepts it.
    /// A text view will, a plain view will not, so the key equivalent is handled here as well —
    /// once, and only for Escape.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EscapeClosableWindow.isEscape(event) {
            onCancel?()
            return true                     // consumed here, so it cannot close a second window too
        }
        return super.performKeyEquivalent(with: event)
    }

    static func isEscape(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && (event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}")
    }
}

/// The scoped-invalidation half of the policy, shared by every view that adopts it.
///
/// `hovering` is the scope. Nothing in here changes the cursor unless this particular view is the
/// one under the pointer, so disabling a button in a hidden panel cannot reach out and reset the
/// I-beam you are holding over a text field somewhere else.
protocol CursorHosting: NSView {
    var hovering: Bool { get set }
    var wantsPointingHand: Bool { get }
}

extension CursorHosting {
    /// Re-apply, or hand back, after something changed that `cursorUpdate` will not be told about:
    /// the control was disabled, the row stopped being clickable, the view left the window.
    func refreshCursorIfHovering() {
        guard hovering else { return }
        if window == nil || isHidden || window?.isVisible == false {
            hovering = false
            ClickCursor.release()
            return
        }
        ClickCursor.apply(enabled: wantsPointingHand)
    }

    /// Called when the view is going away under a stationary pointer.
    func releaseCursorOnDisappear() {
        guard hovering else { return }
        hovering = false
        ClickCursor.release()
    }
}

/// A view whose whole area is one click target.
///
/// It also takes hit-testing away from its own decoration: a label or an image inside a button-like
/// view would otherwise both keep its own cursor and swallow the click meant for the parent. Real,
/// interactive controls are still allowed through, so a card can contain working buttons.
class ClickableView: NSView, CursorHosting {
    var onClick: (() -> Void)?
    /// Set false for a row that is only informative; it then claims nothing.
    var isClickable = true {
        didSet {
            guard isClickable != oldValue else { return }
            refreshCursorIfHovering()
        }
    }

    var hovering = false
    var wantsPointingHand: Bool { isClickable }

    private var tracking: NSTrackingArea?
    private var pressed = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: ClickCursor.trackingOptions, owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        hovering = true
        ClickCursor.apply(enabled: isClickable)
    }

    /// The pointer has arrived — carrying whatever shape the last window gave it.
    ///
    /// This is the message a non-key window really receives, so this is where the cursor is claimed.
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        ClickCursor.apply(enabled: isClickable, from: self, event: "entered")
    }

    /// And re-claimed on movement: another application can reassert its own cursor while the
    /// pointer is still inside ours, and movement is the only chance to take it back.
    override func mouseMoved(with event: NSEvent) {
        hovering = true
        ClickCursor.apply(enabled: isClickable, from: self, event: "moved")
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        ClickCursor.release()
    }

    /// The panel is torn down and rebuilt on every render, and hidden without the pointer moving.
    /// Both are moments where a hand would otherwise be left behind.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { releaseCursorOnDisappear() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        releaseCursorOnDisappear()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = isClickable
    }

    /// Fire on release, and only if the pointer is still inside **and we are still clickable**.
    ///
    /// Acting on mouse-down would open a terminal when you press on a card and drag away — the
    /// standard way to change your mind. Re-reading `isClickable` matters for the same reason: if a
    /// re-render turns the row informative between press and release, the press must not still act.
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, isClickable,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    /// Decoration inside this view is not a separate target. Real controls are — including
    /// **disabled** ones.
    ///
    /// Two different questions, and conflating them is what caused the bug. "Is it a control?" is
    /// wrong, because `NSTextField` is one and a plain label would keep its own I-beam and swallow
    /// the card's click. But "can it be acted on?" is wrong too: a *disabled* button answers no, and
    /// handing its clicks to the card behind it means pressing a greyed-out control opens a
    /// terminal. A disabled control keeps its own hit, does nothing with it, and shows an arrow.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === self { return self }
        if ClickableView.isDecoration(hit) { return isClickable ? self : hit }
        return hit
    }

    /// Something drawn on the card that was never a target in its own right: a label you cannot
    /// select or edit, an image, a bare container view.
    static func isDecoration(_ view: NSView) -> Bool {
        if let field = view as? NSTextField {
            return !field.isEditable && !field.isSelectable
        }
        return !(view is NSControl)
    }

    /// A button you can press, or a field you can type in or select text from. A label is neither,
    /// and neither is a disabled button — which is why it gets an arrow rather than a hand.
    static func isInteractive(_ view: NSView) -> Bool {
        if let field = view as? NSTextField {
            return field.isEditable || field.isSelectable
        }
        if let control = view as? NSControl {
            return control.isEnabled
        }
        return false
    }
}

/// NSButton with a closure instead of a target/action pair, and a cursor that tells the truth.
final class ClosureButton: NSButton, CursorHosting {
    var handler: (() -> Void)?
    /// Set when this button's menu carries a session-context item.
    var contextHandler: ((AgentAttentionCore.SessionIdentity) -> Void)?
    /// Set when this button's menu carries a pairing item.
    var linkHandler: ((AgentAttentionCore.SessionIdentity) -> Void)?
    /// Set when this button's menu carries a snooze item.
    var itemHandler: ((AgentAttentionCore.AttentionItem) -> Void)?
    /// Set when this button's menu carries a dismiss item.
    var secondaryItemHandler: ((AgentAttentionCore.AttentionItem) -> Void)?
    /// Swapped in by `--uicheck` so a menu can be inspected without a tracking loop.
    var menuPresenter: ((NSMenu) -> Void)?

    var hovering = false
    var wantsPointingHand: Bool { isEnabled }

    /// A button that is switched off under a stationary pointer must give the hand back at once —
    /// `cursorUpdate` will not fire again until the pointer moves.
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            refreshCursorIfHovering()
        }
    }

    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(fire)
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(fire)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: ClickCursor.trackingOptions, owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        hovering = true
        // A disabled button is not a click target and must not pretend to be one.
        ClickCursor.apply(enabled: isEnabled)
    }

    /// A disabled button still takes the cursor — it just takes it back to an arrow. Leaving an
    /// I-beam over a greyed-out control would be the same lie in a different shape.
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        ClickCursor.apply(enabled: isEnabled, from: self, event: "entered")
    }

    override func mouseMoved(with event: NSEvent) {
        hovering = true
        ClickCursor.apply(enabled: isEnabled, from: self, event: "moved")
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        ClickCursor.release()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { releaseCursorOnDisappear() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        releaseCursorOnDisappear()
    }

    @objc private func fire() {
        handler?()
    }
}
