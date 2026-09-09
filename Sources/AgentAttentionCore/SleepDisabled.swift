import Foundation

/// Whether the machine's global lid-close sleep block is set, as `pmset` reports it.
///
/// This exists because a privileged write that is not read back is a hope, not a fact.
/// `SleepDisabled` is a single machine-wide boolean with no notion of ownership, so the
/// only way to know a transition happened is to look. An answer we cannot parse is
/// `unknown` and never `off`: reporting a setting as cleared when we did not see it
/// cleared is exactly the lie that would leave a lid-closed Mac awake in a bag.
public enum SleepDisabled: String, Sendable, Equatable {
    case on
    case off
    case unknown

    /// Parse the output of `pmset -g`. The key appears under "System-wide power settings:"
    /// as `SleepDisabled` followed by whitespace and 0 or 1.
    public static func parse(_ pmsetOutput: String) -> SleepDisabled {
        for line in pmsetOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // Exactly two fields, the first of which is the key itself — not a line that
            // merely contains it.
            guard fields.count == 2, fields[0] == "SleepDisabled" else { continue }
            switch fields[1] {
            case "1": return .on
            case "0": return .off
            default: return .unknown
            }
        }
        return .unknown
    }
}
