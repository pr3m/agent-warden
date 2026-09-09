/// What the machine's power situation is right now.
public struct PowerReading: Sendable, Equatable {
    /// Battery percentage, or nil when it cannot be read. Nil is *not* zero.
    public var percent: Int?
    /// Whether the machine is plugged in. If we misread AC state, the guard might fire
    /// while plugged in, breaking the guarantee that on AC there is always power.
    public var onAC: Bool
    public init(percent: Int?, onAC: Bool) {
        self.percent = percent
        self.onAC = onAC
    }
}

/// What action the guard has decided to take.
///
/// The guard returns `none` for every situation where sleeping would be premature or
/// impossible. It returns `exitAndSleep` only when the battery is low enough on battery
/// power to risk a hard shutdown.
public enum RoamGuardAction: Sendable, Equatable {
    /// Do nothing — roam is off, or the machine is on AC, or the battery is unreadable,
    /// or the threshold is misconfigured. Each of these is a distinct reason to take no
    /// action, unified by the principle that we only exit when we can read the battery
    /// and know it is critically low.
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
    /// Sane bounds for a hand-edited config. The minimum is 1 because the guard fires when
    /// `percent <= threshold`. A threshold of 0 would fire only when the battery reads exactly
    /// 0%, leaving no margin to write state and sleep cleanly — the guard would activate at the
    /// moment all power is already gone. A threshold of 1 is the smallest value that provides
    /// any buffer, firing at both 1% and 0%.
    /// The maximum is 50 because a threshold of 200 would fire on every tick, defeating
    /// the purpose of a threshold.
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
