import Foundation

/// Whether the session list is on screen — and, more to the point, **who put it there**.
///
/// The rule is one sentence: only the user opens the panel. A new ask changes the badge on the
/// bubble; it does not put a window over what somebody is reading. The app used to expand the panel
/// whenever an ask arrived, which meant a session in another worktree finishing a turn threw a list
/// across the screen of whoever happened to be working.
///
/// The distinction this keeps is between a *signal* and a *presentation*. Arriving work is a signal
/// — the count moves, and a chime may sound, both independently of any window. Presenting the list
/// is an action, and every path to it here starts with a person.
///
/// Nothing in this type asks for focus. The panel is a non-activating window, and `wantsFocus` is a
/// constant `false` so that a future change has to argue with a test rather than with a comment.
public struct PanelPresentation: Sendable, Equatable {
    /// Is the list on screen?
    public private(set) var isExpanded = false
    /// Did the user open it? An emptied queue closes a panel that opened itself, and leaves alone
    /// one the user opened.
    public private(set) var openedByUser = false

    public init() {}

    /// Never true. Presenting this list must not take focus from anything.
    public var wantsFocus: Bool { false }

    // MARK: - Things that happen on their own
    //
    // Every one of these is deliberately a no-op for visibility. They are listed separately rather
    // than folded into one `somethingHappened()` so that adding a new automatic trigger means
    // writing a method here — and noticing that it must not open anything.

    /// A genuine ask arrived. The badge changes; the window does not.
    public mutating func attentionRaised() {}
    /// The same ask, described again.
    public mutating func attentionRepeated() {}
    /// A snooze ran out. The item is waiting again, which is a badge, not a window.
    public mutating func snoozeExpired() {}
    /// A registry scan found sessions.
    public mutating func sessionsDiscovered() {}
    /// The app started with a queue already saved.
    public mutating func restoredPendingItems(count: Int) {}
    /// Maintenance ran.
    public mutating func sweepRan() {}
    /// A background job started, finished or went quiet.
    public mutating func backgroundActivityChanged() {}
    /// The app came forward for some other reason.
    public mutating func applicationActivated() {}

    // MARK: - Things a person did

    /// The bubble was clicked, or the menu item chosen. The only way in.
    public mutating func userToggled() {
        isExpanded.toggle()
        openedByUser = isExpanded
    }

    /// A click somewhere else. The view is put away; nothing in the queue is decided.
    public mutating func clickedAway() {
        isExpanded = false
        openedByUser = false
    }

    /// Nothing is waiting any more. A panel that opened itself goes away; one the user opened is
    /// theirs to close.
    public mutating func queueEmptied() {
        guard !openedByUser else { return }
        isExpanded = false
    }

    /// Closed by the app for a reason of its own — quitting, the bubble being switched off.
    public mutating func forceCollapsed() {
        isExpanded = false
        openedByUser = false
    }

    /// What the bubble shows. Stated here so the badge and the list are read from one place.
    public func badgeCount(pending: Int) -> Int { max(0, pending) }
}
