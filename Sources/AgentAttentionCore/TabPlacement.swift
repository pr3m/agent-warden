import Foundation

/// Where one terminal sits in Ghostty's tab bar right now, and what its tab is currently called.
///
/// **Why position, and not just a name.** The panel's job is to get somebody to the right session,
/// and the fastest route to a tab is the key that selects it. Ghostty binds ⌘1…⌘9 to a tab's
/// position *within its window*, so a row that says `3 - groom red tickets` is telling you which key
/// to press, not decorating the name. The number is per window and never continuous across windows,
/// because a continuous number would stop matching ⌘N for every window after the first — a number
/// that lies is worse than no number.
///
/// **Why this is read repeatedly and not stored once.** A tab title is not fixed. A person renames a
/// tab, `/warden:label` writes a new one, and tabs are dragged and closed all day — so a name and a
/// position captured when the session was first linked go out of date within minutes. That is
/// exactly the bug this exists to close: four rows reading `Claude Code` while their tabs plainly
/// said something a person had chosen. Everything here is a reading, valid at the moment it was
/// taken, and it is taken again.
public struct TabPlacement: Codable, Sendable, Equatable {
    /// The stable terminal id — the only field ever matched against a saved link.
    public var terminalID: String
    /// 1-based position of the tab in its own window. This is the ⌘N number.
    public var tabIndex: Int
    /// 1-based position of the window. Recorded so a caller can tell two windows apart; never shown
    /// on its own, because the user asked for the bare tab number.
    public var windowIndex: Int
    /// The title the tab is showing at this instant, decoration and all. Callers reduce it with
    /// `TabName.readable` — it is kept raw here so the reading stays a reading.
    public var name: String?

    public init(terminalID: String, tabIndex: Int, windowIndex: Int, name: String? = nil) {
        self.terminalID = terminalID
        self.tabIndex = tabIndex
        self.windowIndex = windowIndex
        self.name = name
    }
}

/// Reads Ghostty's window → tab → terminal layout out of the one line of text a script returns.
///
/// Split from the adapter so the parsing can be exercised without a terminal, and because the shape
/// of that text is the part most likely to be wrong: a tab title is arbitrary user text and may
/// contain newlines, tabs, separators, anything. Fields are therefore delimited by the ASCII unit
/// and record separators, which a title cannot realistically contain — splitting on newlines would
/// invent tabs that do not exist.
public enum TabLayout {
    /// Longest terminal id we will look at. Ghostty issues UUIDs; anything longer is not one.
    static let maximumIDLength = 128

    /// Every terminal in the layout, in window then tab order. Unreadable records are dropped
    /// rather than guessed at — a record we cannot parse is not a tab.
    public static func parse(_ text: String) -> [TabPlacement] {
        text.components(separatedBy: "\u{1E}").compactMap { record in
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let fields = trimmed.components(separatedBy: "\u{1F}")
            guard fields.count >= 3,
                  let windowIndex = Int(fields[0].trimmingCharacters(in: .whitespaces)),
                  let tabIndex = Int(fields[1].trimmingCharacters(in: .whitespaces)),
                  windowIndex > 0, tabIndex > 0 else { return nil }
            let id = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= maximumIDLength else { return nil }
            // A title is arbitrary text from outside this app, so it is bounded here as well as
            // where it is drawn.
            let name = fields.count > 3 ? String(fields[3].prefix(200)) : nil
            return TabPlacement(terminalID: id, tabIndex: tabIndex, windowIndex: windowIndex,
                                name: name)
        }
    }

    /// Which saved links this reading changes, and to what.
    ///
    /// Pure, and separate from the reading, so the policy can be exercised without a terminal or a
    /// disk. Three rules, each of which was a bug before it was a rule:
    ///
    /// - **Matched on terminal id only.** Matching a tab by what it is called is the guess the whole
    ///   pairing design exists to avoid — it sends somebody to a stranger's session.
    /// - **The stored name is the readable one.** A live title carries a spinner and a context
    ///   percentage that change several times a second; storing those would mean rewriting the file
    ///   several times a second to say nothing new.
    /// - **A title that reduces to nothing leaves the name alone.** Decoration is not a name, and
    ///   replacing a good name with an empty one is a regression dressed as a refresh.
    public static func applying(placements: [String: TabPlacement],
                                to pairings: [String: TerminalPairing]) -> [String: TerminalPairing] {
        var changed: [String: TerminalPairing] = [:]
        for (sessionID, pairing) in pairings {
            guard let placement = placements[pairing.terminalID] else { continue }
            var next = pairing
            if let readable = TabName.readable(placement.name) { next.terminalName = readable }
            next.tabIndex = placement.tabIndex
            if next != pairing { changed[sessionID] = next }
        }
        return changed
    }
}
