import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("The roam footer indicator")
struct RoamIndicatorTests {

    private let t0 = Date(timeIntervalSince1970: 4_000_000)

    private func live() -> RoamState {
        RoamState(active: true, startedAt: t0, ownerPID: 4711, ownerPIDStartedAt: 500,
                  leaseRenewedAt: t0, enteredOnBattery: false)
    }

    @Test("An active session prints the badge")
    func printsWhenOn() {
        #expect(RoamIndicator.text(state: live(), now: t0, probe: { _ in 500 }) == "🎒 roam on")
    }

    @Test("No state at all prints nothing")
    func silentWhenAbsent() {
        #expect(RoamIndicator.text(state: nil, now: t0, probe: { _ in 500 }) == "")
    }

    /// The bug this closes: SIGKILL Warden and the file stays behind. Without validation
    /// every session footer on the machine would keep claiming the lid was safe to close.
    @Test("A file left behind by a dead app prints nothing")
    func silentWhenOwnerIsGone() {
        #expect(RoamIndicator.text(state: live(), now: t0, probe: { _ in nil }) == "")
    }

    @Test("A stale lease prints nothing")
    func silentWhenLeaseIsStale() {
        #expect(RoamIndicator.text(state: live(), now: t0.addingTimeInterval(120),
                                   probe: { _ in 500 }) == "")
    }
}
