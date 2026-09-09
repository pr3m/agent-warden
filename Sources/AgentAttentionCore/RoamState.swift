import Foundation

/// Which phone hotspot roam believes it is on, as of entry.
public struct RoamHotspot: Codable, Sendable, Equatable {
    public var kind: String
    public var ssid: String?
    public init(kind: String, ssid: String? = nil) {
        self.kind = kind
        self.ssid = ssid
    }
}

/// What roam has on disk, so a status line and a CLI can answer without asking the app.
///
/// **A file cannot say "while I am alive".** Roam is only real while a live process holds
/// an idle assertion and a renewed lease; a `SIGKILL` skips every cleanup path and leaves
/// this file behind saying roam is on when nothing at all is holding the machine awake.
/// So the file is stamped with the owner's process fingerprint and the last lease renewal,
/// and every reader validates both. The same fingerprint trick guards `pairings.json`
/// against recycled PIDs, for the same reason: a PID on its own is reused within hours.
///
/// The file exists **if and only if** roam is fully established — assertion held, lease
/// acquired, and `SleepDisabled` verified. There is no half-entered state to describe.
public struct RoamState: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var active: Bool
    public var startedAt: Date
    public var ownerPID: Int32
    public var ownerPIDStartedAt: Double
    public var leaseRenewedAt: Date
    public var enteredOnBattery: Bool
    public var hotspot: RoamHotspot?
    public var nudgeSnoozedUntil: Date?

    public init(schema: Int = RoamState.currentSchema, active: Bool, startedAt: Date,
                ownerPID: Int32, ownerPIDStartedAt: Double, leaseRenewedAt: Date,
                enteredOnBattery: Bool, hotspot: RoamHotspot? = nil,
                nudgeSnoozedUntil: Date? = nil) {
        self.schema = schema
        self.active = active
        self.startedAt = startedAt
        self.ownerPID = ownerPID
        self.ownerPIDStartedAt = ownerPIDStartedAt
        self.leaseRenewedAt = leaseRenewedAt
        self.enteredOnBattery = enteredOnBattery
        self.hotspot = hotspot
        self.nudgeSnoozedUntil = nudgeSnoozedUntil
    }

    /// How long after the last confirmed renewal this file still describes a live session.
    ///
    /// **`PowerLease.expiry`, referenced and not retyped.** These two numbers are the same fact
    /// seen from two sides: the daemon drops the machine's sleep block `PowerLease.expiry`
    /// seconds after the holder's last renewal, so a `roam.json` older than that describes a
    /// session whose block is already gone. It sat here as a bare `45` in the same module as the
    /// constant it was copying — which is not a comment that can go stale, it is a *number* that
    /// can, silently, the next time somebody tunes the lease and reasonably assumes one edit was
    /// enough. Then `aa-roam status` and the status line would keep printing `🎒 roam on` for
    /// however long the two had drifted apart. `RoamStateTests` asserts the tie in both
    /// directions rather than trusting this comment to be read.
    public static let defaultLeaseWindow: TimeInterval = PowerLease.expiry

    /// Is this state still true right now?
    ///
    /// - Parameter probe: returns the start time of the given PID, or nil if no such
    ///   process. Injected so the rule can be exercised without a real process.
    public func isLive(now: Date = Date(), leaseWindow: TimeInterval = RoamState.defaultLeaseWindow,
                       probe: (Int32) -> Double?) -> Bool {
        guard active else { return false }
        guard let started = probe(ownerPID) else { return false }
        // Same tolerance as ProcessFingerprint: a start time a second or two apart is the
        // same process; anything else is a recycled PID wearing its number.
        guard abs(started - ownerPIDStartedAt) <= 2.0 else { return false }
        return now.timeIntervalSince(leaseRenewedAt) <= leaseWindow
    }
}
