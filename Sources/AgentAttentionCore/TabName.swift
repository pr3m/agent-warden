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
}
