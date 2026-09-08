import Foundation
import Testing
@testable import AgentAttentionCore

/// Owning a surface means acting on **that** surface and no other.
///
/// The defect these exist for is not hypothetical. `repeat with t in terminals` binds a *positional*
/// reference — `item N of every terminal` — rather than the terminal itself. Storing it and acting
/// on it later closes whatever is at position N at that moment. Observed live: a close aimed at a
/// test tab reported `closed`, the test tab survived, and a different tab — someone's running
/// session, in another project — disappeared. Closing a tab takes its work with it, so the rule here
/// is that a reference which can no longer be shown to name the wanted id is not acted on at all.
@Suite("Ghostty surface ownership")
struct SurfaceOwnershipTests {
    private let wanted = "B5EE12C7-9F06-4DFA-B41F-DAA021B7E2AF"

    // MARK: - The script itself

    @Test("The script dereferences the match instead of storing a position")
    func theScriptDereferencesTheMatch() {
        let source = GhosttySurfaceAdapter.actOnMatchedTerminal(id: wanted, verb: "close", answer: "closed")
        #expect(source.contains("(contents of t)"),
                "a bare `set target to t` stores `item N of every terminal`, not a terminal")
        #expect(!source.contains("set target to t\n"), "the positional form must be gone")
    }

    @Test("The id is read again immediately before the verb runs")
    func theIdentityIsRecheckedBeforeActing() {
        let source = GhosttySurfaceAdapter.actOnMatchedTerminal(id: wanted, verb: "close", answer: "closed")
        guard let guardLine = source.range(of: "if (id of target) is not wanted then return \"moved\""),
              let verbLine = source.range(of: "close target") else {
            Issue.record("the script no longer has both an identity guard and a verb")
            return
        }
        #expect(guardLine.upperBound < verbLine.lowerBound,
                "the check has to come before the action, or it checks nothing")
    }

    @Test("The wanted id is compared, not merely interpolated once")
    func theWantedIdIsBoundOnce() {
        let source = GhosttySurfaceAdapter.actOnMatchedTerminal(id: wanted, verb: "focus", answer: "focused")
        #expect(source.contains("set wanted to \"\(wanted)\""))
        #expect(source.contains("if (id of t) is wanted"))
    }

    // MARK: - What the answers mean
    //
    // Asserted on the mapping itself rather than through an adapter. The script gate is process-wide
    // by design, so a suite running beside this one can legitimately make an adapter answer `.busy`
    // — which would make these tests report on the scheduler rather than on the rule they are about.

    @Test("A close whose reference moved is a failure, never a reported success")
    func aMovedReferenceIsNotAClose() {
        #expect(throws: GhosttySurfaceFailure.self) {
            try GhosttySurfaceAdapter.closeOutcome("moved").get()
        }
    }

    @Test("A focus whose reference moved is refused rather than sent somewhere else")
    func aMovedReferenceIsNotAFocus() {
        #expect(throws: GhosttySurfaceFailure.self) {
            try GhosttySurfaceAdapter.focusOutcome("moved").get()
        }
    }

    @Test("An answer nobody recognises is a refusal, not a success")
    func anUnknownAnswerIsARefusal() {
        for answer in ["", "ok", "closed the wrong one", "true"] {
            #expect(throws: GhosttySurfaceFailure.self) {
                try GhosttySurfaceAdapter.closeOutcome(answer).get()
            }
        }
    }

    @Test("A terminal that is already gone is a successful close, because the outcome asked for holds")
    func anAlreadyGoneTerminalIsASuccessfulClose() throws {
        try GhosttySurfaceAdapter.closeOutcome("gone").get()
        try GhosttySurfaceAdapter.closeOutcome("closed").get()
    }

    @Test("A terminal that is gone cannot be focused, and says so")
    func anAlreadyGoneTerminalCannotBeFocused() {
        if case .failure(let failure) = GhosttySurfaceAdapter.focusOutcome("gone") {
            #expect(failure == .surfaceGone)
        } else {
            Issue.record("focusing a terminal that is gone must not report success")
        }
    }

    @Test("A focus that really happened is a success")
    func aRealFocusIsASuccess() throws {
        try GhosttySurfaceAdapter.focusOutcome("focused").get()
    }

    @Test("The script carries the id it was asked for, and only that one")
    func theScriptNamesOneTerminal() {
        let source = GhosttySurfaceAdapter.actOnMatchedTerminal(id: wanted, verb: "close", answer: "closed")
        #expect(source.components(separatedBy: wanted).count - 1 == 1,
                "the wanted id is bound once and compared, never re-interpolated")
    }

    // MARK: - Which window a session opens in

    @Test("A window count that could not be read never counts as no window")
    func anUnreadableWindowCountDoesNotOpenASecondWindow() {
        // The live failure: `hasOpenWindow` flattened every error to false, so a script that failed
        // for any reason opened a *second* Ghostty window beside the one the user already had.
        for failure: GhosttySurfaceFailure in [.scriptingFailed, .permissionDenied, .surfaceGone] {
            #expect(GhosttySurfaceAdapter.hasOpenWindow(from: .failure(failure)) == true,
                    "an unanswered question is not an answer of zero")
        }
    }

    @Test("An unreadable window count is reported as a failure, not as a number")
    func anUnreadableCountIsAFailure() {
        #expect(throws: GhosttySurfaceFailure.self) {
            try GhosttySurfaceAdapter.windowCount(from: "not a number").get()
        }
    }

    @Test("A definite zero is the only thing that opens a new window")
    func onlyADefiniteZeroOpensANewWindow() throws {
        #expect(try GhosttySurfaceAdapter.windowCount(from: "0").get() == 0)
        #expect(GhosttySurfaceAdapter.hasOpenWindow(from: .success(0)) == false)
        #expect(GhosttySurfaceAdapter.hasOpenWindow(from: .success(1)) == true)
        #expect(GhosttySurfaceAdapter.hasOpenWindow(from: .success(3)) == true)
    }
}
