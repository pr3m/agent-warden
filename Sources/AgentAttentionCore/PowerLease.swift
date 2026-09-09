import Foundation

/// Who currently holds the machine's lid-close sleep block, and until when.
///
/// **Why a lease and not a flag.** The failure that actually costs something is a Mac
/// left awake with the lid shut and nobody watching: the battery goes flat and the work
/// is lost. Tying the block to a lease means the dangerous state cannot outlive the thing
/// that asked for it.
///
/// **Why the lease expires as well as dropping on disconnect.** A closed socket catches an
/// app that exited or crashed. It does not catch one that is alive but wedged —
/// deadlocked, `SIGSTOP`ped, or simply no longer running its own timers. Those are the
/// cases where the socket stays open forever, so the lease carries a deadline the holder
/// must keep pushing out.
///
/// Pure on purpose: no clock, no socket, no `pmset`. The caller supplies the time and the
/// observed setting, and applies the returned effect. That makes every rule here testable
/// without root, a machine, or a wait.
public struct PowerLease: Sendable {
    /// How often the holder is expected to renew.
    public static let renewInterval: TimeInterval = 10
    /// How long after the last renewal the lease dies. Three missed beats plus slack:
    /// long enough that a busy machine does not lose its block, short enough that a wedged
    /// app cannot flatten the battery.
    public static let expiry: TimeInterval = 45

    /// The privileged side effect the daemon must apply after a decision, or none.
    /// Kept separate from `PowerReply` because the reply is what the app is told and the
    /// effect is what `pmset` is told — conflating them would tempt the daemon into
    /// inferring one from the other instead of applying exactly what the lease decided.
    public enum Effect: Sendable, Equatable {
        /// No change to the machine's sleep setting is needed.
        case none
        /// Set `SleepDisabled` — a new lease was just granted.
        case setBlock
        /// Clear `SleepDisabled` — the lease that held it is gone (released, expired, or
        /// the holder disconnected).
        case clearBlock
    }

    /// The result of one state transition: what to tell the caller, and what the daemon
    /// must do to `pmset` as a result. Bundled together so a call site cannot apply one
    /// without the other and drift the reported state from the real one.
    public struct Decision: Sendable, Equatable {
        public var reply: PowerReply
        public var effect: Effect
        public init(reply: PowerReply, effect: Effect) {
            self.reply = reply
            self.effect = effect
        }
    }

    /// The connection holding the lease, or nil when the block is free.
    public private(set) var holder: Int?
    private var deadline: Date?

    public init() {}

    public mutating func acquire(connection: Int, observed: SleepDisabled, now: Date) -> Decision {
        if let holder, holder != connection {
            return Decision(reply: .error(.busy), effect: .none)
        }
        switch observed {
        case .on where holder == nil:
            // Somebody else's block. `SleepDisabled` has no ownership identity, so taking
            // it over would mean stealing it, and clearing it later would mean ending
            // their session. Refuse and say so.
            return Decision(reply: .error(.foreign), effect: .none)
        case .unknown:
            return Decision(reply: .error(.unverified), effect: .none)
        default:
            holder = connection
            deadline = now.addingTimeInterval(PowerLease.expiry)
            return Decision(reply: .ok, effect: .setBlock)
        }
    }

    public mutating func renew(connection: Int, now: Date) -> Decision {
        guard holder == connection else { return Decision(reply: .error(.nolease), effect: .none) }
        deadline = now.addingTimeInterval(PowerLease.expiry)
        return Decision(reply: .ok, effect: .none)
    }

    public mutating func release(connection: Int) -> Decision {
        guard holder == connection else { return Decision(reply: .error(.nolease), effect: .none) }
        holder = nil
        deadline = nil
        return Decision(reply: .ok, effect: .clearBlock)
    }

    public func status(now: Date, observed: SleepDisabled) -> Decision {
        guard holder != nil, let deadline else {
            return Decision(reply: .free(setting: observed), effect: .none)
        }
        let remaining = max(0, Int(deadline.timeIntervalSince(now).rounded(.down)))
        return Decision(reply: .held(secondsRemaining: remaining, setting: observed), effect: .none)
    }

    /// A connection closed. Only the holder's closing means anything.
    public mutating func disconnected(connection: Int) -> Effect {
        guard holder == connection else { return .none }
        holder = nil
        deadline = nil
        return .clearBlock
    }

    /// The daemon itself is stopping. Give the lease up, whoever holds it.
    ///
    /// Distinct from `release` and `disconnected` because neither of those fits: both are a
    /// *holder* giving something back and both are addressed to one connection, so both refuse
    /// to act on behalf of anybody else — correctly, since a peer must never be able to end
    /// another peer's session. This is the daemon speaking about itself, and it has no
    /// connection to name. Distinct from `expireIfDue` too: nothing here is overdue, and a
    /// shutdown that waited for the deadline would leave the block standing.
    ///
    /// Called from the `SIGTERM` handler, which is the case that made it necessary: `launchctl
    /// bootout` and an upgrade both stop this process politely, and a daemon that exits without
    /// clearing `SleepDisabled` leaves a machine that cannot sleep with nothing left running that
    /// knows why. Startup reconciliation would repair it — at the *next* boot, which is a long
    /// way away for a Mac that will not sleep.
    public mutating func relinquish() -> Effect {
        guard holder != nil else { return .none }
        holder = nil
        deadline = nil
        return .clearBlock
    }

    /// Called from the daemon's own timer, which must be independent of the connection
    /// read loop — a timer driven by that loop would stop exactly when the loop hangs.
    public mutating func expireIfDue(now: Date) -> Effect {
        guard holder != nil, let deadline, now >= deadline else { return .none }
        holder = nil
        self.deadline = nil
        return .clearBlock
    }
}
