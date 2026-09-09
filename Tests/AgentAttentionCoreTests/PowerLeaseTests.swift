import Foundation
import Testing
@testable import AgentAttentionCore

/// The lease is what makes the safety claims true. Each test below is a failure that
/// would otherwise leave a lid-closed Mac awake with nobody watching.
@Suite("The sleep-block lease")
struct PowerLeaseTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("Acquiring a free block sets it and hands out the lease")
    func acquireWhenFree() {
        var lease = PowerLease()
        let decision = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(decision.reply == .ok)
        #expect(decision.effect == .setBlock)
        #expect(lease.holder == 1)
    }

    /// Verified live on 2026-09-09: `SleepDisabled` was already 1 because a separate tool
    /// had an active session. A daemon that took it over would have silently ended that
    /// session; a daemon that cleared it on exit would have ended it later and worse.
    @Test("A block somebody else already holds is refused, never taken over")
    func acquireRefusesForeignBlock() {
        var lease = PowerLease()
        let decision = lease.acquire(connection: 1, observed: .on, now: t0)
        #expect(decision.reply == .error(.foreign))
        #expect(decision.effect == .none)
        #expect(lease.holder == nil)
    }

    @Test("A reading we could not make is not treated as free")
    func acquireRefusesUnknownReading() {
        var lease = PowerLease()
        let decision = lease.acquire(connection: 1, observed: .unknown, now: t0)
        #expect(decision.reply == .error(.unverified))
        #expect(decision.effect == .none)
    }

    @Test("Only one lease exists at a time")
    func secondAcquireIsBusy() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        let decision = lease.acquire(connection: 2, observed: .off, now: t0)
        #expect(decision.reply == .error(.busy))
        #expect(decision.effect == .none)
        #expect(lease.holder == 1)
    }

    @Test("Only the holder may renew or release")
    func nonHolderCannotRenewOrRelease() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.renew(connection: 2, now: t0).reply == .error(.nolease))
        #expect(lease.release(connection: 2).reply == .error(.nolease))
        #expect(lease.holder == 1)
    }

    /// The failure a connection-only lease misses entirely: an app that is alive, holding
    /// the socket open, but wedged — deadlocked, SIGSTOPped, or no longer running its sweep.
    @Test("A lease nobody renews expires on its own")
    func leaseExpires() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(44)) == .none)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(46)) == .clearBlock)
        #expect(lease.holder == nil)
    }

    @Test("Renewing pushes the deadline out")
    func renewExtends() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.renew(connection: 1, now: t0.addingTimeInterval(30)).reply == .ok)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(70)) == .none)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(80)) == .clearBlock)
    }

    @Test("An expired lease clears the block exactly once")
    func expiryIsNotRepeated() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(60)) == .clearBlock)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(90)) == .none)
    }

    @Test("The holder disconnecting clears the block immediately")
    func disconnectReleases() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.disconnected(connection: 1) == .clearBlock)
        #expect(lease.holder == nil)
    }

    /// A short-lived `status` connection must never own cleanup — otherwise every
    /// `aa-roam status` would end the roam session it was asking about.
    @Test("A connection that never held the lease releases nothing when it drops")
    func statusConnectionOwnsNothing() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.disconnected(connection: 2) == .none)
        #expect(lease.holder == 1)
    }

    @Test("Status reports the remaining time and what was actually observed")
    func statusReportsReality() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        let held = lease.status(now: t0.addingTimeInterval(5), observed: .on)
        #expect(held.reply == .held(secondsRemaining: 40, setting: .on))
        let free = PowerLease()
        #expect(free.status(now: t0, observed: .off).reply == .free(setting: .off))
    }

    /// I9. The daemon's SIGTERM handler needs a way to give the block back on behalf of a holder
    /// it is not, and neither `release` nor `disconnected` will do it: both are addressed to one
    /// connection and both correctly refuse to act for anybody else.
    @Test("A daemon that is stopping gives the block back whoever holds it")
    func relinquishClearsAnyHolder() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 7, observed: .off, now: t0)
        #expect(lease.holder == 7)
        #expect(lease.relinquish() == .clearBlock)
        #expect(lease.holder == nil)
        // And it says nothing needs undoing when nothing is held, so a stopping daemon that
        // never granted a lease does not run `pmset` to clear a block it never set.
        #expect(lease.relinquish() == .none)
    }

    @Test("Relinquishing a lease nobody holds is a no-op, not a clear")
    func relinquishOnAFreeLeaseDoesNothing() {
        var lease = PowerLease()
        #expect(lease.relinquish() == .none)
        #expect(lease.holder == nil)
    }

    @Test("The heartbeat interval leaves room for missed beats")
    func intervalsAreSane() {
        #expect(PowerLease.renewInterval == 10)
        #expect(PowerLease.expiry == 45)
        #expect(PowerLease.expiry > PowerLease.renewInterval * 3)
    }
}
