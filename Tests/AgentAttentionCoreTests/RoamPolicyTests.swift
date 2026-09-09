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
