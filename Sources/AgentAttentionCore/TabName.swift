import Foundation

/// The name a person actually gave a terminal tab, with the live decoration taken off.
///
/// **Why this is not "inventing a name".** The rule everywhere else here is that a session is only
/// called what somebody chose to call it — never something derived from a transcript, a directory or
/// a model. A tab title qualifies: the user typed it, or a tool they installed writes it on their
/// behalf. Until the handshake existed there was no way to read it, so the fallback was the worktree
/// folder — which is why four tabs in one repository all read "Redmy" while their tabs plainly said
/// `client-info t1`, `release prep` and `velocity analysis`.
///
/// What is stripped is decoration that changes second by second and belongs to the terminal rather
/// than the name: a leading status glyph (spinner, tick, question mark) and a trailing context
/// percentage. A name that is *only* decoration is no name at all, and answers nil so the caller
/// keeps whatever it had.
public enum TabName {
    /// A tab title reduced to the part a person would call it, or nil if nothing is left.
    public static func readable(_ title: String?) -> String? {
        guard var text = title?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        // Trailing "·81%" / "· 81 %" — the context meter, not part of the name.
        text = text.replacingOccurrences(of: "\\s*[·•]\\s*\\d{1,3}\\s*%\\s*$", with: "",
                                         options: .regularExpression)
        // Leading status glyph and the space after it. Braille spinners, ticks, crosses, emoji: all
        // of them are the tool saying what the session is doing, which the row already says itself.
        text = text.replacingOccurrences(of: "^[^\\p{L}\\p{N}]+", with: "",
                                         options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bounded, because a title is arbitrary text from outside this app.
        guard !text.isEmpty, text.count <= 60 else { return text.isEmpty ? nil : String(text.prefix(60)) }
        return text
    }

    /// A name with its tab's ⌘N number in front: `3 - groom red tickets`.
    ///
    /// The number is the tab's position in its own window, which is the key that selects it. It is
    /// only added when there is a real position to add — an unlinked session has no tab, and
    /// inventing a number for it would send somebody to a stranger's tab. Ghostty binds ⌘1…⌘9, so
    /// anything past that is still shown (the position is true) but there is no key for it.
    public static func numbered(index: Int?, name: String) -> String {
        guard let index, index > 0, index <= 99 else { return name }
        return "\(index) - \(name)"
    }
}
