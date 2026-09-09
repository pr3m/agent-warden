import Foundation

/// The one string a Claude Code session footer shows for roam.
///
/// Deliberately trivial and deliberately validated. It runs on every status-line refresh, so it
/// reads one file and makes no IPC call — but it must never print from a file that a killed app
/// left behind, because "🎒 roam on" is a claim that the lid is safe to close. Retiring the old
/// `claude-code-roam` plugin means Warden itself is now the only thing that can make that claim
/// honestly, since it is the only reader that knows roam's liveness rule (`RoamState.isLive`).
public enum RoamIndicator {
    /// The exact text a live session prints. Fixed, not built from `RoamState`, because there is
    /// nothing state-dependent to show — the footer answers one yes/no question, not "since when"
    /// or "on which network".
    public static let badge = "🎒 roam on"

    /// What the footer should print for the given state, right now.
    ///
    /// - Parameters:
    ///   - state: what `roam.json` last said, or nil if there is no file at all.
    ///   - now: injected so a stale lease can be tested without waiting on a real clock.
    ///   - probe: answers `RoamState.isLive`'s question about the owning process. See its own
    ///     doc for why a PID alone is not enough.
    /// - Returns: `badge` when roam is on and validated; `""` in every other case, including no
    ///   file, a dead owner, and a stale lease. Silence is the safe default for a status line that
    ///   nobody is required to read before closing their lid.
    public static func text(state: RoamState?, now: Date = Date(),
                            probe: (Int32) -> Double?) -> String {
        guard let state, state.isLive(now: now, probe: probe) else { return "" }
        return badge
    }
}
