import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("What the roam menu item says")
struct RoamMenuTextTests {

    @Test("Each state says what it is, and a disabled one says why")
    func titles() {
        #expect(RoamMenuText.title(for: .on) == "Turn roam off")
        #expect(RoamMenuText.title(for: .off) == "Turn roam on")
        #expect(RoamMenuText.title(for: .unavailable).contains("install.sh"))
        #expect(RoamMenuText.title(for: .foreign).contains("another tool"))
    }

    @Test("Only the two real states are actionable")
    func enablement() {
        #expect(RoamMenuText.isActionable(.on))
        #expect(RoamMenuText.isActionable(.off))
        #expect(!RoamMenuText.isActionable(.unavailable))
        #expect(!RoamMenuText.isActionable(.foreign))
    }

    @Test("A change in flight disables an otherwise-actionable state")
    func isChangingDisablesActionableStates() {
        #expect(RoamMenuText.isEnabled(state: .on, isChanging: false))
        #expect(RoamMenuText.isEnabled(state: .off, isChanging: false))
        #expect(!RoamMenuText.isEnabled(state: .on, isChanging: true))
        #expect(!RoamMenuText.isEnabled(state: .off, isChanging: true))
    }

    /// `isChanging` cannot make an already-disabled state clickable — there is no state for
    /// it to fall back to.
    @Test("A change in flight cannot make an unactionable state enabled")
    func isChangingCannotRescueUnactionableStates() {
        #expect(!RoamMenuText.isEnabled(state: .unavailable, isChanging: false))
        #expect(!RoamMenuText.isEnabled(state: .unavailable, isChanging: true))
        #expect(!RoamMenuText.isEnabled(state: .foreign, isChanging: false))
        #expect(!RoamMenuText.isEnabled(state: .foreign, isChanging: true))
    }

    @Test("The notice line carries the sentence and how long ago it was said")
    func noticeLineCarriesTextAndAge() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        #expect(RoamMenuText.noticeLine(text: "Battery at 8% — ended roam.", at: at, now: at)
                == "Battery at 8% — ended roam. — just now")
        #expect(RoamMenuText.noticeLine(text: "x", at: at, now: at.addingTimeInterval(150))
                == "x — 2m ago")
        #expect(RoamMenuText.noticeLine(text: "x", at: at, now: at.addingTimeInterval(3 * 3600))
                == "x — 3h ago")
        #expect(RoamMenuText.noticeLine(text: "x", at: at, now: at.addingTimeInterval(2 * 86400))
                == "x — 2d ago")
    }

    /// A notice from hours ago is not hidden — see `noticeLine`'s doc for why: the scenario
    /// it exists for is a lid opened long after the notice was posted.
    @Test("An old notice still renders, with its age")
    func oldNoticeStillRenders() {
        let at = Date(timeIntervalSince1970: 0)
        let now = at.addingTimeInterval(30 * 86400)
        #expect(RoamMenuText.noticeLine(text: "still here", at: at, now: now) == "still here — 30d ago")
    }
}
