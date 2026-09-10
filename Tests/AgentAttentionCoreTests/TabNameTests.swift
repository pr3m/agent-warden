import Foundation
import Testing
@testable import AgentAttentionCore

/// What a tab is called, once the live decoration is off it.
///
/// The names here are real ones from a running desk: four tabs in one repository, all of which the
/// app called "Atlas" because the worktree folder was the only name it could reach.
@Suite("Reading a tab's name")
struct TabNameTests {

    @Test("A spinner and a context meter are decoration, not name", arguments: [
        ("⠦ client-info t1 ·92%", "client-info t1"),
        ("✅ release prep ·75%", "release prep"),
        ("⠹ velocity analysis", "velocity analysis"),
        ("◑ orbit-961", "orbit-961"),
        ("⠧ agent-warden", "agent-warden"),
        ("? client-info t1 ·92%", "client-info t1"),
    ])
    func decorationIsStripped(title: String, expected: String) {
        #expect(TabName.readable(title) == expected)
    }

    @Test("A plain name is left exactly as it is")
    func aPlainNameSurvives() {
        #expect(TabName.readable("atlas") == "atlas")
        #expect(TabName.readable("Sales CRM — offer flow") == "Sales CRM — offer flow")
    }

    @Test("Nothing, or only decoration, is not a name")
    func decorationAloneIsNotAName() {
        for title in [nil, "", "   ", "⠦", "👻", "✅ "] {
            #expect(TabName.readable(title) == nil, "\(title ?? "nil") is not something to call a session")
        }
    }

    @Test("A percentage inside the name is not mistaken for the meter")
    func onlyATrailingMeterIsRemoved() {
        #expect(TabName.readable("50% faster parser") == "50% faster parser")
        #expect(TabName.readable("⠦ 50% faster parser ·81%") == "50% faster parser")
    }

    @Test("An arbitrary title cannot become an arbitrarily long row")
    func theNameIsBounded() {
        let long = String(repeating: "a", count: 500)
        #expect(TabName.readable(long)?.count == 60)
    }
}
