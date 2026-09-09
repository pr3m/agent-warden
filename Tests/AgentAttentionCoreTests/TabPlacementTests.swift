import Foundation
import Testing
@testable import AgentAttentionCore

/// Where a tab sits, and keeping that in step with a tab bar somebody is rearranging.
///
/// The layouts here are real ones, read off a running desk: seven tabs in one window and one in a
/// second, with the spinner and context meter Claude Code paints into every title.
@Suite("Reading the tab bar")
struct TabPlacementTests {

    /// The exact shape `GhosttyAdapter.readTabLayout` asks for: unit separator between fields,
    /// record separator between terminals.
    private func record(_ window: Int, _ tab: Int, _ id: String, _ name: String) -> String {
        "\(window)\u{1F}\(tab)\u{1F}\(id)\u{1F}\(name)\u{1E}"
    }

    @Test("A whole window's tabs come back in order, numbered from one")
    func aWindowIsRead() {
        let text = record(1, 1, "ADE9AC8B", "✅ redmy ·91%")
            + record(1, 2, "95864ADE", "✅ redmy")
            + record(1, 3, "037D96FA", "⠦ groom red tickets")
            + record(2, 1, "B5EE12C7", "👻")
        let tabs = TabLayout.parse(text)
        #expect(tabs.count == 4)
        #expect(tabs.map(\.tabIndex) == [1, 2, 3, 1])
        #expect(tabs.map(\.windowIndex) == [1, 1, 1, 2])
        #expect(tabs[2].terminalID == "037D96FA")
        // Raw here on purpose: reducing the name is the caller's decision, not the reader's.
        #expect(tabs[2].name == "⠦ groom red tickets")
    }

    @Test("The number restarts in the second window, because ⌘N does")
    func numbersArePerWindow() {
        let text = record(1, 1, "A", "one") + record(2, 1, "B", "two")
        let tabs = TabLayout.parse(text)
        #expect(tabs.map(\.tabIndex) == [1, 1])
        #expect(tabs.map(\.windowIndex) == [1, 2])
    }

    @Test("A title containing a newline is one tab, not two")
    func aNewlineInATitleInventsNothing() {
        let tabs = TabLayout.parse(record(1, 1, "A", "release\nprep") + record(1, 2, "B", "redmy"))
        #expect(tabs.count == 2)
        #expect(tabs[0].name == "release\nprep")
    }

    @Test("A record that cannot be read is dropped, never guessed at", arguments: [
        "1\u{1F}2\u{1E}",                       // no id
        "1\u{1F}2\u{1F}\u{1E}",                 // empty id
        "x\u{1F}2\u{1F}A\u{1E}",                // window is not a number
        "1\u{1F}x\u{1F}A\u{1E}",                // tab is not a number
        "1\u{1F}0\u{1F}A\u{1E}",                // positions are 1-based; 0 is not one
    ])
    func unreadableRecordsAreDropped(text: String) {
        #expect(TabLayout.parse(text).isEmpty)
    }

    @Test("A good tab survives a bad one beside it")
    func oneBadRecordDoesNotLoseTheRest() {
        let tabs = TabLayout.parse("1\u{1F}x\u{1F}A\u{1E}" + record(1, 2, "B", "redmy"))
        #expect(tabs.count == 1)
        #expect(tabs[0].terminalID == "B")
    }

    @Test("An empty tab bar is an empty answer, not a failure")
    func nothingIsNothing() {
        #expect(TabLayout.parse("").isEmpty)
        #expect(TabLayout.parse("   \n ").isEmpty)
    }

    @Test("An arbitrary title cannot become an arbitrarily long record")
    func theNameIsBounded() {
        let tabs = TabLayout.parse(record(1, 1, "A", String(repeating: "z", count: 900)))
        #expect(tabs[0].name?.count == 200)
    }
}

/// Folding a fresh reading into the saved links.
@Suite("Keeping a row in step with its tab")
struct TabTitleSyncTests {

    private func pairing(session: String, terminal: String, name: String?, index: Int? = nil)
        -> TerminalPairing {
        TerminalPairing(sessionID: session, claudePID: 100, claudePIDStartedAt: 1,
                        terminalAppBundleID: "com.mitchellh.ghostty", terminalAppPID: 7,
                        terminalAppStartedAt: 1, terminalID: terminal, terminalName: name,
                        tabIndex: index, pairedAt: Date(), provenance: "derivedHandshake")
    }

    /// The bug this closes: a session linked while its tab still said the launch command, then
    /// renamed by the person sitting in front of it.
    @Test("A renamed tab renames its row")
    func arenameIsPickedUp() {
        let saved = ["s1": pairing(session: "s1", terminal: "A", name: "claude --resume 7ccdb3ff")]
        let seen = ["A": TabPlacement(terminalID: "A", tabIndex: 3, windowIndex: 1,
                                      name: "⠦ groom red tickets")]
        let changed = TabLayout.applying(placements: seen, to: saved)
        #expect(changed["s1"]?.terminalName == "groom red tickets")
        #expect(changed["s1"]?.tabIndex == 3)
    }

    @Test("A tab dragged to a new position gets the new number")
    func areorderIsPickedUp() {
        let saved = ["s1": pairing(session: "s1", terminal: "A", name: "redmy", index: 5)]
        let seen = ["A": TabPlacement(terminalID: "A", tabIndex: 2, windowIndex: 1, name: "redmy")]
        #expect(TabLayout.applying(placements: seen, to: saved)["s1"]?.tabIndex == 2)
    }

    /// Titles change several times a second as the spinner turns and the context meter moves. If
    /// that counted as a change, the links file would be rewritten several times a second.
    @Test("The spinner turning is not a change")
    func decorationIsNotAChange() {
        let saved = ["s1": pairing(session: "s1", terminal: "A", name: "redmy", index: 1)]
        for title in ["⠦ redmy ·91%", "✅ redmy ·04%", "⠹ redmy"] {
            let seen = ["A": TabPlacement(terminalID: "A", tabIndex: 1, windowIndex: 1, name: title)]
            #expect(TabLayout.applying(placements: seen, to: saved).isEmpty,
                    "\(title) says nothing new about the session")
        }
    }

    @Test("A tab showing only decoration keeps the name it had")
    func anEmptyTitleDoesNotEraseAName() {
        let saved = ["s1": pairing(session: "s1", terminal: "A", name: "redmy", index: 1)]
        let seen = ["A": TabPlacement(terminalID: "A", tabIndex: 4, windowIndex: 1, name: "👻")]
        let changed = TabLayout.applying(placements: seen, to: saved)
        #expect(changed["s1"]?.terminalName == "redmy")   // kept
        #expect(changed["s1"]?.tabIndex == 4)             // and the position is still true
    }

    /// The rule the whole pairing design rests on: a tab is found by its id, never by its name.
    @Test("A session whose terminal is not in the reading is left completely alone")
    func anAbsentTerminalChangesNothing() {
        let saved = ["s1": pairing(session: "s1", terminal: "GONE", name: "redmy", index: 1)]
        let seen = ["OTHER": TabPlacement(terminalID: "OTHER", tabIndex: 1, windowIndex: 1,
                                          name: "redmy")]
        #expect(TabLayout.applying(placements: seen, to: saved).isEmpty)
    }

    @Test("Two windows can both hold a tab 1, and each row says so")
    func twoWindowsBothStartAtOne() {
        let saved = [
            "s1": pairing(session: "s1", terminal: "A", name: "redmy"),
            "s2": pairing(session: "s2", terminal: "B", name: "wunda-961"),
        ]
        let seen = [
            "A": TabPlacement(terminalID: "A", tabIndex: 1, windowIndex: 1, name: "redmy"),
            "B": TabPlacement(terminalID: "B", tabIndex: 1, windowIndex: 2, name: "wunda-961"),
        ]
        let changed = TabLayout.applying(placements: seen, to: saved)
        #expect(changed["s1"]?.tabIndex == 1)
        #expect(changed["s2"]?.tabIndex == 1)
    }
}

/// What the row actually reads.
@Suite("Numbering a row")
struct NumberedNameTests {

    @Test("The number goes in front, exactly as asked for")
    func theNumberLeads() {
        #expect(TabName.numbered(index: 1, name: "redmy") == "1 - redmy")
        #expect(TabName.numbered(index: 5, name: "planned backlog review")
            == "5 - planned backlog review")
    }

    @Test("A session with no tab gets no number", arguments: [nil, 0, -1, 100])
    func nothingIsInventedForAnUnlinkedSession(index: Int?) {
        #expect(TabName.numbered(index: index, name: "redmy") == "redmy")
    }
}
