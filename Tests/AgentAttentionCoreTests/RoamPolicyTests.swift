import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("The roam battery guard")
struct RoamPolicyTests {

    private func act(_ percent: Int?, onAC: Bool = false, active: Bool = true,
                     threshold: Int = 10) -> RoamGuardAction {
        RoamPolicy.guardAction(reading: PowerReading(percent: percent, onAC: onAC),
                               threshold: threshold, roamActive: active)
    }

    @Test("At or below the threshold on battery, roam exits and the Mac sleeps")
    func firesAtThreshold() {
        #expect(act(10) == .exitAndSleep(percent: 10))
        #expect(act(3) == .exitAndSleep(percent: 3))
    }

    @Test("Above the threshold, nothing happens")
    func quietAboveThreshold() {
        #expect(act(11) == .none)
        #expect(act(100) == .none)
    }

    /// On AC there is nothing to guard against — the whole point of the threshold is to
    /// save work before the charge runs out.
    @Test("On AC power the guard never fires")
    func neverOnAC() {
        #expect(act(5, onAC: true) == .none)
        #expect(act(1, onAC: true) == .none)
    }

    @Test("With roam off there is nothing to exit")
    func nothingToGuardWhenOff() {
        #expect(act(1, active: false) == .none)
    }

    /// A battery we cannot read is not an empty battery. Sleeping the machine on a
    /// missing reading would be worse than the thing it is protecting against.
    @Test("An unreadable battery does not trigger a sleep")
    func unknownBatteryIsNotEmpty() {
        #expect(act(nil) == .none)
    }

    @Test("A nonsensical threshold cannot make the guard fire constantly")
    func thresholdIsClamped() {
        #expect(act(50, threshold: 200) == .none)
        #expect(act(50, threshold: -5) == .none)
    }
}

@Suite("Whether roam may start at all")
struct RoamEntryActionTests {

    private func decide(_ percent: Int?, onAC: Bool = false, threshold: Int = 10) -> RoamEntryAction {
        RoamPolicy.entryAction(reading: PowerReading(percent: percent, onAC: onAC), threshold: threshold)
    }

    @Test("At or below the threshold on battery, entry is refused with the reading that caused it")
    func refusesAtThreshold() {
        #expect(decide(10) == .refuse(percent: 10))
        #expect(decide(3) == .refuse(percent: 3))
    }

    @Test("Above the threshold, roam may proceed")
    func proceedsAboveThreshold() {
        #expect(decide(11) == .proceed)
        #expect(decide(100) == .proceed)
    }

    /// The bug this closes: granting entry at 8% against a 10% threshold used to let roam
    /// start and then watch `guardAction` undo it on the very next heartbeat. The two must
    /// agree at the boundary, or entry would reopen exactly the gap the guard closes.
    @Test("entryAction refuses everywhere guardAction would immediately reverse the entry")
    func agreesWithTheGuardAtTheBoundary() {
        for percent in 0...20 {
            let reading = PowerReading(percent: percent, onAC: false)
            let entry = RoamPolicy.entryAction(reading: reading, threshold: 10)
            let guardResult = RoamPolicy.guardAction(reading: reading, threshold: 10, roamActive: true)
            switch (entry, guardResult) {
            case (.refuse, .exitAndSleep), (.proceed, .none):
                continue
            default:
                Issue.record("entry and guard disagreed at \(percent)%: \(entry) vs \(guardResult)")
            }
        }
    }

    /// On AC there is nothing to refuse over — the whole reason this gate exists is a charge
    /// that will not last the session.
    @Test("On AC power entry is never refused")
    func neverRefusesOnAC() {
        #expect(decide(5, onAC: true) == .proceed)
        #expect(decide(1, onAC: true) == .proceed)
    }

    /// A battery we cannot read is not an empty battery. Refusing roam over a reading that
    /// never arrived would block it for a reason that might not exist.
    @Test("An unreadable battery does not refuse entry")
    func unknownBatteryProceeds() {
        #expect(decide(nil) == .proceed)
    }

    @Test("A nonsensical threshold cannot block every roam session")
    func thresholdIsClamped() {
        #expect(decide(5, threshold: 200) == .proceed)
        #expect(decide(5, threshold: -5) == .proceed)
    }
}
