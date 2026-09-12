import Foundation

/// Writing a tab's name where the warden shell plugin will read it.
///
/// **Why this app writes into another tool's directory, having never done so before.** Warden owns
/// the terminal title — it has to, to animate a spinner in it — and repaints it every tick, so a
/// title this app writes to a tty is gone within a second. Warden's own escape hatch is a label
/// file per tty, which it treats as the name and keeps decorating. Writing that file is therefore
/// the only way a derived name survives, and it is the same thing `warden label` does.
///
/// The coupling is real and deliberately narrow: one path shape, one line of text, no reads of
/// warden's other state, and every failure is silent. If warden is not installed there is no
/// sessions directory, nothing is created, and the caller is told the name did not stick.
public enum WardenLabelFile {
    /// `/dev/ttys003` → `<home>/.claude/warden/sessions/_dev_ttys003.label`
    ///
    /// The filename rule is warden's, matched exactly: every character that is not a letter or a
    /// digit becomes an underscore. A different rule here would write a file warden never reads,
    /// which fails by doing nothing visible — the worst shape of failure.
    public static func path(forTTY tty: String, home: String = NSHomeDirectory()) -> URL {
        let safe = String(tty.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/warden/sessions")
            .appendingPathComponent("\(safe).label")
    }

    /// Write a name for one tab. Returns whether it stuck.
    ///
    /// Refuses to create the sessions directory: its existence is how this tells "warden is
    /// installed" from "warden is not", and a naming pass that installs half of another tool is
    /// not what anyone asked for.
    @discardableResult
    public static func write(_ name: String, forTTY tty: String,
                             home: String = NSHomeDirectory()) -> Bool {
        let cleaned = strip(name)
        guard !cleaned.isEmpty else { return false }
        let url = path(forTTY: tty, home: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path,
                                             isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        return (try? Data((cleaned + "\n").utf8).write(to: url, options: .atomic)) != nil
    }

    /// What warden's own reader would make of a label: first line, no control characters, and no
    /// `|`, which is a field separator in its status bus and would corrupt a row.
    public static func strip(_ name: String) -> String {
        let firstLine = name.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let kept = firstLine.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "|"
        }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    }
}
