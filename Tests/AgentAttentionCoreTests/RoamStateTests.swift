import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("Roam state and whether it is still true")
struct RoamStateTests {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func state(pid: Int32 = 4711, started: Double = 500,
                       renewed: Date? = nil) -> RoamState {
        RoamState(active: true, startedAt: t0, ownerPID: pid, ownerPIDStartedAt: started,
                  leaseRenewedAt: renewed ?? t0, enteredOnBattery: false,
                  hotspot: RoamHotspot(kind: "iphone", ssid: "phone"), nudgeSnoozedUntil: nil)
    }

    /// The owner is alive and the lease is fresh: roam really is on.
    @Test("Live owner plus a fresh lease reads as active")
    func liveAndFresh() {
        let live = state()
        #expect(live.isLive(now: t0.addingTimeInterval(5), leaseWindow: 45,
                           probe: { _ in 500 }))
    }

    /// The bug this closes: SIGKILL leaves the file behind, and the footer would keep
    /// claiming the lid was safe to close long after nothing was holding it open.
    @Test("A dead owner reads as inactive, whatever the file says")
    func deadOwnerIsNotActive() {
        #expect(!state().isLive(now: t0, leaseWindow: 45, probe: { _ in nil }))
    }

    /// A recycled PID is a different process. Matching on the number alone would adopt
    /// a stranger's process as the owner of a roam session.
    @Test("A recycled PID is not the same owner")
    func recycledPIDIsNotTheOwner() {
        #expect(!state().isLive(now: t0, leaseWindow: 45, probe: { _ in 9_999 }))
    }

    @Test("A lease nobody has renewed reads as inactive")
    func staleLeaseIsNotActive() {
        let stale = state(renewed: t0)
        #expect(!stale.isLive(now: t0.addingTimeInterval(46), leaseWindow: 45,
                              probe: { _ in 500 }))
    }

    @Test("A file that says inactive is inactive regardless of liveness")
    func inactiveIsInactive() {
        var off = state()
        off.active = false
        #expect(!off.isLive(now: t0, leaseWindow: 45, probe: { _ in 500 }))
    }

    /// I4. The window used to be a bare `45` sitting in the same module as `PowerLease.expiry`,
    /// which is the number it was copying. Tuning the lease and leaving this behind would not
    /// break a test or produce a warning — it would just make `aa-roam status` and the status
    /// line keep printing `🎒 roam on` for however long the two had drifted, which is the exact
    /// class of lie roam is not allowed to tell. Asserted in both directions: the constant is the
    /// same value, and the *behaviour* pivots on it rather than on a number written here.
    @Test("The default lease window is the daemon's expiry, and the behaviour follows it")
    func leaseWindowIsTiedToTheLeaseExpiry() {
        #expect(RoamState.defaultLeaseWindow == PowerLease.expiry)

        let session = state(renewed: t0)
        // One second inside the daemon's expiry: the block is still held, so this is still live.
        #expect(session.isLive(now: t0.addingTimeInterval(PowerLease.expiry - 1),
                               probe: { _ in 500 }))
        // One second past it: the daemon has dropped the block, so the file must not claim roam.
        #expect(!session.isLive(now: t0.addingTimeInterval(PowerLease.expiry + 1),
                                probe: { _ in 500 }))
    }

    @Test("State round-trips through JSON")
    func roundTrips() throws {
        let encoded = try JSONCoding.encoder.encode(state())
        #expect(try JSONCoding.decoder.decode(RoamState.self, from: encoded) == state())
    }
}
