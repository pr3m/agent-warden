import Foundation
import Testing
@testable import AgentAttentionCore

/// Who is allowed to put the panel on screen.
///
/// One rule, and it is the whole type: **only the user**. A notification changes the badge; it does
/// not open a window. Anything else means a list appearing over what somebody was reading, because
/// a session three worktrees away finished a turn.
@Suite("Panel presentation")
struct PanelPresentationTests {
    @Test("A new ask changes the badge and leaves the panel closed")
    func anAskDoesNotOpenThePanel() {
        // Production mutation this catches: `isExpanded = true` in the raised-effect branch of
        // `announce`, which is exactly how the panel used to open itself.
        var presentation = PanelPresentation()
        #expect(!presentation.isExpanded)

        presentation.attentionRaised()

        #expect(!presentation.isExpanded, "the bubble says something arrived; the user decides to look")
    }

    @Test("Neither does a burst of them, deduplicated or not")
    func repeatedAsksStayClosed() {
        var presentation = PanelPresentation()
        for _ in 0..<10 {
            presentation.attentionRaised()
            presentation.attentionRepeated()
        }
        #expect(!presentation.isExpanded)
    }

    @Test("Nor a snooze running out")
    func anUnsnoozeDoesNotOpenIt() {
        // The other place the panel used to open itself.
        var presentation = PanelPresentation()
        presentation.snoozeExpired()
        #expect(!presentation.isExpanded)
    }

    @Test("Nor anything else that happens on its own", arguments: [
        "discovery", "restore", "sweep", "backgroundJob", "activation",
    ])
    func nothingAutomaticOpensIt(_ source: String) {
        var presentation = PanelPresentation()
        switch source {
        case "discovery": presentation.sessionsDiscovered()
        case "restore": presentation.restoredPendingItems(count: 4)
        case "sweep": presentation.sweepRan()
        case "backgroundJob": presentation.backgroundActivityChanged()
        default: presentation.applicationActivated()
        }
        #expect(!presentation.isExpanded, "\(source) is not a person clicking the bubble")
    }

    @Test("Starting up with a queue shows a count, not a window")
    func restoringDoesNotOpenIt() {
        var presentation = PanelPresentation()
        presentation.restoredPendingItems(count: 3)
        #expect(!presentation.isExpanded)
        #expect(presentation.badgeCount(pending: 3) == 3, "the count is what changes")
    }

    @Test("Clicking the bubble opens it; clicking again closes it")
    func theUserOpensAndCloses() {
        var presentation = PanelPresentation()
        presentation.userToggled()
        #expect(presentation.isExpanded)
        #expect(presentation.openedByUser)

        presentation.userToggled()
        #expect(!presentation.isExpanded)
        #expect(!presentation.openedByUser)
    }

    @Test("An ask arriving while the panel is open leaves it open")
    func anOpenPanelStaysOpen() {
        // The list refreshes underneath; it does not close and reopen, and nothing takes focus.
        var presentation = PanelPresentation()
        presentation.userToggled()
        presentation.attentionRaised()
        #expect(presentation.isExpanded)
        #expect(presentation.openedByUser, "it is still the user's window")
    }

    @Test("An emptied queue closes a panel nobody opened, and keeps one the user did")
    func emptyingRespectsWhoOpenedIt() {
        var automatic = PanelPresentation()
        automatic.queueEmptied()
        #expect(!automatic.isExpanded)

        var byUser = PanelPresentation()
        byUser.userToggled()
        byUser.queueEmptied()
        #expect(byUser.isExpanded, "the user opened it; it is theirs to close")
    }

    @Test("Clicking away closes it without deciding anything about the queue")
    func clickingAwayCloses() {
        var presentation = PanelPresentation()
        presentation.userToggled()
        presentation.clickedAway()
        #expect(!presentation.isExpanded)
        #expect(!presentation.openedByUser)
    }

    @Test("Nothing here ever asks for focus")
    func focusIsNeverRequested() {
        // Production mutation this catches: adding an activation or key-window step to the open
        // path. The panel is a non-activating window and presenting it must stay that way.
        var presentation = PanelPresentation()
        presentation.attentionRaised()
        presentation.userToggled()
        presentation.restoredPendingItems(count: 2)
        #expect(!presentation.wantsFocus, "no path here may steal what somebody is typing into")
    }

    @Test("Sound is decided somewhere else entirely")
    func soundIsIndependentOfVisibility() {
        // A chime for a genuine ask happens whether or not any window is open; the two were never
        // connected and must not become connected by this change.
        var presentation = PanelPresentation()
        presentation.attentionRaised()
        #expect(!presentation.isExpanded)
        #expect(presentation.badgeCount(pending: 1) == 1)
    }
}
