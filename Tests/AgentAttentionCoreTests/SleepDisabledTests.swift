import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("Reading SleepDisabled back")
struct SleepDisabledTests {

    /// Verbatim from `pmset -g` on a machine where lid-close sleep was blocked.
    private let blocked = """
    System-wide power settings:
     SleepDisabled\t\t1
    Currently in use:
     standby              1
     hibernatefile        /var/vm/sleepimage
    """

    private let free = """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standby              1
    """

    @Test("The setting is read as itself, not inferred")
    func readsBothStates() {
        #expect(SleepDisabled.parse(blocked) == .on)
        #expect(SleepDisabled.parse(free) == .off)
    }

    /// A reading we cannot make is never reported as "off". Treating an unreadable
    /// answer as off would let the daemon claim it had cleared a setting it never saw.
    @Test("An answer we cannot read is unknown, never off", arguments: [
        "", "   ", "System-wide power settings:", "SleepDisabled", "SleepDisabled\tmaybe",
    ])
    func unreadableIsUnknown(output: String) {
        #expect(SleepDisabled.parse(output) == .unknown)
    }

    @Test("The key is matched exactly, not as a substring")
    func doesNotMatchLookalikes() {
        #expect(SleepDisabled.parse(" NotSleepDisabledReally\t1") == .unknown)
    }
}
