import Foundation

/// What the roam menu item should say and whether it can be used right now.
///
/// Lives in Core, not the app target, because `BubbleMenu` (where the item is actually built)
/// cannot be imported by tests — anything worth unit-testing has to live here instead.
/// `BubbleMenu.roamItem` is the single constructor that turns this into an `NSMenuItem`, and
/// `RoamMenuText` below is the only thing that interprets it into a title or an enabled flag.
/// The bubble's menu and the menu-bar menu are built at different moments — one on right-click,
/// one on every render — but both derive their state from the same facts on `AppDelegate`
/// (`RoamService.isActive`, whether the daemon's socket exists, the last foreign-hold answer),
/// so they can only disagree if those facts themselves change between the two builds, which is
/// exactly the "roam changed" case that also triggers a redraw of both.
public enum RoamMenuState: Equatable, Sendable {
    /// Roam is on: the idle assertion is held, the lease is granted, and the lid can be
    /// closed. Clicking the item turns it off.
    case on
    /// Roam is off: closing the lid sleeps the Mac as it normally would. Clicking the item
    /// asks the daemon for the lease.
    case off
    /// The power helper (`dev.agentwarden.powerd`) could not be reached, so there is no
    /// daemon to ask for the machine-wide sleep block. Clicking could not do anything, and a
    /// toggle that quietly failed would be worse than one that says why it is disabled.
    case unavailable
    /// Something other than Agent Warden already holds the machine's sleep block — for
    /// example, `sudo pmset -a disablesleep 1` run by hand, or a roam plugin that has not been
    /// uninstalled yet. The daemon refuses to take over a setting it did not set itself, so
    /// roam cannot start until that external hold is cleared, and the item says so rather than
    /// failing silently on click.
    ///
    /// **Unlike `.unavailable`, this one is still clickable**, and that is deliberate. This
    /// state is *remembered from the last attempt* — there is no proactive way to learn it (see
    /// `AppDelegate.roamForeignHold`), so nothing in the app can notice the external hold going
    /// away. Left un-actionable, the flag had exactly one writer, `toggleRoam`, which a disabled
    /// item can never reach: one `error foreign` and roam was gone until the app was restarted,
    /// even after the user had cleared the hold. Asking again is both the only way to find out
    /// and free when it fails, so the item invites it.
    case foreign
}

/// The text and enablement for `RoamMenuState`, kept as pure functions so they can be unit
/// tested without ever building an `NSMenuItem`. `BubbleMenu.roamItem` is the only caller.
public enum RoamMenuText {
    /// Which of the four states we are in, from the three facts that decide it.
    ///
    /// This is the one piece of roam-menu logic that used to live only in `AppDelegate`, where
    /// nothing could exercise it directly: the Core suite cannot see it, and `--uicheck`
    /// injects `RoamMenuState` values rather than deriving them. Lifted here so the mapping —
    /// which of four things the user is told — is itself unit tested, not just the text and
    /// enablement that follow from it.
    ///
    /// **Order matters, and `isActive` must be checked first.** If roam is already on, that is
    /// the answer regardless of the other two facts — including a helper that has since become
    /// unreachable, which must still read `.on` (and so still let the user click to end it)
    /// rather than switch to `.unavailable` and disable the only path back to `.off`.
    ///
    /// - Parameters:
    ///   - isActive: `RoamService.isActive`.
    ///   - helperPresent: whatever the caller uses to answer "is there a power helper to ask at
    ///     all" — `AppDelegate` answers this by checking whether the daemon's socket file
    ///     exists, but this function only needs the answer, not how it was reached.
    ///   - foreignHold: whether the most recent `enter` attempt reported that something else
    ///     already holds the machine's sleep block. There is no proactive way to know this — see
    ///     `AppDelegate.roamForeignHold`'s doc for why it can only be learned by trying.
    public static func state(isActive: Bool, helperPresent: Bool, foreignHold: Bool) -> RoamMenuState {
        if isActive { return .on }
        guard helperPresent else { return .unavailable }
        return foreignHold ? .foreign : .off
    }

    /// What the item says. A disabled item still explains itself in its own title rather than
    /// only turning grey: "nothing happens when I click it" is the worst answer a menu can
    /// give, and `.unavailable` / `.foreign` each name a different thing to do about it.
    public static func title(for state: RoamMenuState) -> String {
        switch state {
        case .on: return "Turn roam off"
        case .off: return "Turn roam on"
        case .unavailable: return "Roam needs the power helper — run install.sh"
        case .foreign: return "Retry roam — another tool holds sleep"
        }
    }

    /// Whether the state itself is one a click can act on.
    ///
    /// `.on` and `.off` obviously are. `.foreign` is too: it is a memory of the last attempt
    /// rather than a fact anything re-checks, so a click is the only way to find out whether the
    /// external hold has been cleared — and the only thing that can clear
    /// `AppDelegate.roamForeignHold`, whose sole writer is the handler behind this item. A
    /// retry that fails costs one refused socket round trip and says why.
    ///
    /// `.unavailable` is the one that is not: there is no daemon socket to talk to, so a click
    /// has nothing to ask, and the title says what to do instead (run install.sh). That state
    /// *is* re-checked on every render — it is a `stat` of the socket path — so it corrects
    /// itself the moment the helper is installed, without needing a click to notice.
    public static func isActionable(_ state: RoamMenuState) -> Bool {
        state == .on || state == .off || state == .foreign
    }

    /// Whether the item should respond to a click right now. Composes `isActionable` with
    /// `isChanging` rather than folding a fifth case into `RoamMenuState`, because "a change
    /// is in flight" is not a fact about what roam *is* — it is true for an instant on top of
    /// either `.on` or `.off` — and the title stays accurate either way while the click is
    /// merely withheld: `RoamService` resolves a click that arrived anyway correctly (`enter`
    /// answers `.busyChanging`; `exit` records the request and honours it once the change
    /// lands), so this is about not inviting a confusing race, not papering over an unsafe one.
    public static func isEnabled(state: RoamMenuState, isChanging: Bool) -> Bool {
        isActionable(state) && !isChanging
    }

    /// One line for the menu describing the last thing roam had to say, or nil when there is
    /// nothing to show.
    ///
    /// **No hidden expiry.** `RoamService.lastNotice` is already cleared the moment roam is
    /// entered again — a notice about how the *last* session ended has nothing to say about
    /// this one — so by the time this is called, whatever is left is still the most recent
    /// word roam has on the matter, however long ago it was said. Hiding it past some fixed
    /// age would risk hiding it exactly when it matters most: the scenario this row exists for
    /// is a lid opened hours after the battery guard slept the machine, and that is exactly
    /// when the notice must still be there. The age is shown instead, so the reader judges
    /// relevance for themselves rather than the menu deciding it for them.
    ///
    /// - Parameters:
    ///   - text: `RoamService.lastNotice?.text`.
    ///   - at: `RoamService.lastNotice?.at`.
    ///   - now: injected so this is testable without waiting.
    public static func noticeLine(text: String, at: Date, now: Date = Date()) -> String {
        "\(text) — \(age(since: at, now: now))"
    }

    /// A short, human phrase for how long ago something happened.
    ///
    /// Below a minute reads as "just now" rather than "0m ago": both are true, but the second
    /// looks like a rounding error rather than a deliberate answer. A negative age (the clock
    /// moved backwards, or `now` was supplied out of order in a test) is clamped to zero for
    /// the same reason — this is a display string, not a diagnostic for clock skew.
    static func age(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        let minutes = Int(seconds) / 60
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
