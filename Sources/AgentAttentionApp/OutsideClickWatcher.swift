import AppKit

/// Collapses the expanded panel when you click somewhere that is not Agent Warden.
///
/// **Presentation only.** Collapsing hides a view. It never dismisses, snoozes, resolves or in any
/// other way touches the queue: whatever was waiting is still waiting, with the same snoozes and the
/// same badge count, and one click on the bubble brings the panel straight back. Clicking away is
/// how you stop *looking* at something, not how you deal with it.
///
/// How it watches, and why this way:
///
/// - A **global** mouse monitor (`NSEvent.addGlobalMonitorForEvents`) sees only events that were
///   delivered to some *other* application, and by design it cannot consume them. Whatever the user
///   actually clicked still receives its click, in full. Nothing is intercepted or swallowed.
/// - It needs **no Accessibility grant**. That requirement applies to keyboard monitoring; mouse
///   monitoring is ordinary API. The app asks for no new permission and gains no new reach.
/// - Clicks inside our own windows never reach a global monitor at all — they are local events —
///   so the panel, the bubble, their buttons and their drag handling need no special case.
///
/// The one thing that does need care is our own menus. `NSMenu` runs a modal tracking loop, and the
/// click that opens or closes one can surface as a global event. While a menu of ours is tracking,
/// and for a moment after it closes, outside clicks are ignored — otherwise opening **Details** on a
/// card would collapse the panel out from under the menu you had just asked for.
final class OutsideClickWatcher {
    /// Called on the main thread when a click landed outside the app and the panel should close.
    var onOutsideClick: (() -> Void)?

    /// Is one of our own menus on screen right now?
    private(set) var menuIsTracking = false
    private var menuClosedAt: Date?
    private var monitor: Any?

    /// How long after a menu closes an outside click is still treated as part of that interaction.
    ///
    /// The click that dismisses a menu can be delivered to a global monitor either side of the
    /// end-of-tracking notification; the order is not guaranteed. This is a short settling window
    /// for that one ambiguity, and nothing else depends on elapsed time.
    let settleAfterMenu: TimeInterval = 0.3

    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    deinit {
        stop()
    }

    // MARK: - The decision

    /// Should a click that landed outside the app collapse the panel?
    ///
    /// Separated from AppKit so the rule can be exercised directly: it is the whole behaviour, and
    /// "did the panel close when it should" is not something a unit test can ask a window.
    func shouldCollapse(panelIsExpanded: Bool, at moment: Date) -> Bool {
        guard panelIsExpanded else { return false }
        guard !menuIsTracking else { return false }
        if let closed = menuClosedAt, moment.timeIntervalSince(closed) < settleAfterMenu {
            return false
        }
        return true
    }

    // MARK: - Lifecycle

    func start() {
        guard monitor == nil else { return }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuDidBeginTracking),
                           name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuDidEndTracking),
                           name: NSMenu.didEndTrackingNotification, object: nil)

        // Observe only. A global monitor has no way to alter or absorb the event it sees.
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.handleOutsideClick()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
    }

    var isRunning: Bool { monitor != nil }

    // MARK: - Internals, exposed for the checks

    func handleOutsideClick() {
        onOutsideClick?()
    }

    @objc func menuDidBeginTracking(_ notification: Notification) {
        menuIsTracking = true
    }

    @objc func menuDidEndTracking(_ notification: Notification) {
        menuIsTracking = false
        menuClosedAt = clock()
    }

    /// For the checks: drive the menu lifecycle without a window server.
    func debugSetMenuTracking(_ tracking: Bool) {
        if tracking {
            menuDidBeginTracking(Notification(name: NSMenu.didBeginTrackingNotification))
        } else {
            menuDidEndTracking(Notification(name: NSMenu.didEndTrackingNotification))
        }
    }
}
