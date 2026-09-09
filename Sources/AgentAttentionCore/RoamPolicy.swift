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

    /// Whether roam may start at all, given the battery right now.
    ///
    /// Without this, asking for roam at 8% with a 10% guard threshold used to be granted —
    /// the lease is acquired, the assertion taken, `roam.json` written — and then undone
    /// ten seconds later on the very first lease heartbeat, when `guardAction` above fires
    /// and ends the session it just started. That reads as a malfunction: the user watched
    /// roam turn on and then watched it turn straight back off. Refusing up front, with the
    /// reason, is the honest answer.
    ///
    /// **Deliberately the same cutoff as `guardAction`: `percent <= threshold`.** Any looser
    /// cutoff here would let `enter` succeed in exactly the band `guardAction` immediately
    /// reverses, reproducing the bug this exists to close; any tighter one would refuse
    /// battery levels the guard itself considers safe. The two must agree because one is the
    /// gate at the door and the other is the same gate enforced continuously after it.
    ///
    /// Pure, so it is testable without a battery, and it is a policy question — not
    /// something `RoamService` decides — for the same reason `guardAction` is: the wiring
    /// class holds no rules of its own about when roam may or may not run.
    public static func entryAction(reading: PowerReading, threshold: Int) -> RoamEntryAction {
        // On AC there is nothing to refuse over — the whole reason this gate exists is a
        // charge that will not last the session, and that concern does not apply here.
        guard !reading.onAC else { return .proceed }
        // A battery we cannot read is not an empty one, and matches `guardAction`'s reading
        // of the same failure: refusing entry over a reading that never arrived would block
        // roam for a reason that might not exist.
        guard let percent = reading.percent else { return .proceed }
        // A threshold outside the sane range is a misconfiguration, not a signal to act on.
        // Failing open here matches `guardAction`: a typo in `config.json` should not be able
        // to block every future roam session, only to leave the guard itself inert.
        guard thresholdRange.contains(threshold) else { return .proceed }
        return percent <= threshold ? .refuse(percent: percent) : .proceed
    }
}

/// What `entryAction` decided about a request to start roam.
public enum RoamEntryAction: Sendable, Equatable {
    /// Nothing stands in the way of asking the daemon for the lease: the machine is on AC,
    /// or on battery comfortably above the guard's threshold, or the battery could not be
    /// read at all (see `entryAction`'s doc for why that reads as "proceed", not "refuse").
    case proceed
    /// Refused before the daemon was ever asked: the battery is already at or below the
    /// percentage that would end roam on its first heartbeat. `percent` is the reading that
    /// caused the refusal, so the caller can tell the user why without reading it again.
    case refuse(percent: Int)
}
