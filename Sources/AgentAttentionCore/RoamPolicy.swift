import Foundation

/// What the machine's power situation is right now.
public struct PowerReading: Sendable, Equatable {
    /// Battery percentage, or nil when it cannot be read. Nil is *not* zero.
    public var percent: Int?
    public var onAC: Bool
    public init(percent: Int?, onAC: Bool) {
        self.percent = percent
        self.onAC = onAC
    }
}

public enum RoamGuardAction: Sendable, Equatable {
    case none
    /// Exit roam and put the machine to sleep deliberately, while there is still charge.
    case exitAndSleep(percent: Int)
}

/// When roam should end itself.
///
/// The promise roam makes is "close the lid and your work survives". The way that promise
/// is broken is a flat battery, so the guard exists to spend the last of the charge on a
/// clean sleep rather than a hard stop.
///
/// Pure, because the alternative way to test it is to flatten a battery. The caller reads
/// the machine and applies the action.
public enum RoamPolicy {
    /// Sane bounds for a hand-edited config. A threshold of 200 would fire on every tick.
    public static let thresholdRange = 1...50

    public static func guardAction(reading: PowerReading, threshold: Int,
                                   roamActive: Bool) -> RoamGuardAction {
        guard roamActive, !reading.onAC else { return .none }
        // A battery we cannot read is not an empty one. Sleeping the machine because a
        // reading failed would cause exactly the interruption the guard exists to avoid.
        guard let percent = reading.percent else { return .none }
        guard thresholdRange.contains(threshold) else { return .none }
        return percent <= threshold ? .exitAndSleep(percent: percent) : .none
    }
}
