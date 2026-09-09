import Foundation
import IOKit
import IOKit.pwr_mgt

/// Keeps the machine from sleeping because nobody has touched it.
///
/// **Idle sleep only, and deliberately not display sleep.** An earlier draft also asserted
/// `kIOPMAssertionTypePreventUserIdleDisplaySleep`. That is wrong for roam: the lid is
/// shut, so the panel is already off, and holding it awake would spend battery on a screen
/// nobody can see — against a feature whose whole promise is that the work outlives the
/// walk to the café.
///
/// **This is half of roam, never all of it.** An idle assertion stops the *idle* timer; it
/// does not stop the lid. Closing the lid still sleeps the machine unless the machine-wide
/// `SleepDisabled` setting is on, and only root can write that — which is what
/// `PowerLeaseClient` and the daemon exist for. Anything that takes this assertion and
/// calls the result "roam" is telling the user a lie the lid will disprove.
///
/// **Why an assertion and not `caffeinate`.** The assertion dies with this process, which
/// is the safe failure: a forked `caffeinate` outlives its owner and keeps a machine awake
/// with nothing watching it. It also leaves no child process to reap and no pid to lose
/// track of.
///
/// Assertions are advisory. macOS may override one under a thermal or low-power emergency,
/// and nothing here assumes otherwise — this type reports what the kernel told it and makes
/// no promise beyond that.
///
/// **Threading.** Not synchronised, and not meant to be: it is owned and driven from the
/// main thread, alongside the rest of the app's roam state.
final class SleepAssertion {
    /// The kernel's handle for the assertion we hold. Only meaningful while `held` is true:
    /// a failed `IOPMAssertionCreateWithName` may leave anything at all here, which is why
    /// `held` — and never this value — is what decides whether there is something to
    /// release.
    private var identifier = IOPMAssertionID(0)

    /// Whether an assertion is outstanding right now. Kept so `take` is idempotent and
    /// `release` cannot hand a stale or never-initialised id back to the kernel.
    private(set) var held = false

    /// Take the assertion, reporting whether the kernel actually granted it.
    ///
    /// Deliberately **not** `@discardableResult`. The difference between "the idle timer is
    /// held off" and "we asked and were refused" is the difference between roam working and
    /// roam being a claim about a machine that is about to go to sleep, so a caller that
    /// ignores this answer should have to say so in writing.
    ///
    /// Idempotent: taking an assertion twice would leak the first id, and the kernel counts
    /// assertions rather than de-duplicating them, so the leaked one would hold the machine
    /// awake until the process exited.
    func take() -> Bool {
        guard !held else { return true }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            // This string is what `pmset -g assertions` prints next to the assertion, so it
            // names the app and the reason: whoever is wondering why their Mac will not
            // sleep gets an answer from the system, without having to guess.
            "Agent Warden roam" as CFString,
            &identifier
        )
        held = (result == kIOReturnSuccess)
        return held
    }

    /// Give the assertion back. Safe to call when nothing is held, and safe to call twice.
    func release() {
        guard held else { return }
        IOPMAssertionRelease(identifier)
        held = false
        // Cleared so the field can never be mistaken for a live handle. Nothing reads it
        // while `held` is false today; this is what keeps that true if that ever changes.
        identifier = IOPMAssertionID(0)
    }

    /// The assertion must not outlive the object that owns it. It would otherwise survive
    /// until the process exited, which for a menu-bar app that runs for days is indefinite.
    deinit { release() }
}
