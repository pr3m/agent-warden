import Foundation

/// Proposing a name for a session that never got one.
///
/// **Why this exists, when `TabName` says names are not derived.** That rule still holds for the
/// panel: nothing here runs on a timer and nothing here overwrites a name somebody chose. This is
/// the other case — seven tabs open, four of them reading `atlas`, `atlas`, `orbit`, `orbit`,
/// because the hook that asks a session to name itself gets one attempt and a busy session drops
/// it. A folder name shared by four tabs is not a name, and the person looking at the panel is the
/// one asking for a better one.
///
/// **The command rule comes first because it is not a guess.** Three of the four tabs above were
/// running `/orbit-sprint-start checkout-trust-back-half` or its equivalent: the person had already
/// typed the name of the work, in the argument. Turning that slug into a label invents nothing. A
/// model is asked only when no such slug exists — `time to prep next release` has no slug, and only
/// reading the session tells you it became a v0.20.0 release.
public enum SessionNaming {
    /// Tab titles are shown in a menu-bar panel beside a glyph and a percentage. Past this, the
    /// name is what gets truncated.
    public static let maximumLength = 50

    /// A name is a handful of words. More than this and the model answered the question it was
    /// asked with a sentence, which is a refusal to answer, not a name.
    public static let maximumWords = 5

    // MARK: - The command rule

    /// The newest slash-command argument that reads like the name of a piece of work.
    ///
    /// The *newest*, not the first: a session opens with `/orbit-sprint-plan` and a paragraph of
    /// prose, then starts the sprint it just planned. The second invocation is what the tab is
    /// actually doing.
    ///
    /// A slug has to earn it. `5m` from `/loop 5m` is an argument but not a name, so at least one
    /// hyphen is required — which is also what every sprint and ticket argument looks like. Prose
    /// arguments are left to the model rather than truncated into nonsense.
    public static func labelFromCommands(in transcript: String) -> String? {
        var newest: String?
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            // A bounded read starts mid-line, and a fragment can still look like a command.
            guard line.first == "{" else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? String else { continue }
            guard let args = tagged("command-args", in: content), isSlug(args) else { continue }
            newest = args.replacingOccurrences(of: "-", with: " ")
        }
        return newest
    }

    /// The same rule, over a transcript on disk.
    ///
    /// **Why this reads the whole file when nothing else here does.** `TranscriptMetadata` reads a
    /// 64 KB tail, correctly: a cwd is rewritten on every line, so the newest one is always in the
    /// window. A slash command is written once, wherever the person happened to type it — measured
    /// on a real session, `/orbit-sprint-start` sat 4.8 MB into a 6.4 MB transcript, inside neither
    /// a head nor a tail window. A bounded window would have found nothing and silently fallen
    /// through to the model on every session, which is the expensive half of this feature.
    ///
    /// It stays cheap anyway: lines are read a chunk at a time and thrown away, and only a line
    /// actually containing the marker is parsed as JSON. A line too long to be a prompt is skipped
    /// rather than held — a pasted file is not a command.
    public static func labelFromCommands(fileAt url: URL,
                                         maximumBytes: Int = 64 * 1024 * 1024,
                                         chunkBytes: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let marker = "<command-args>"
        let maximumLineBytes = 1 * 1024 * 1024
        var newest: String?
        var carried = Data()
        var read = 0

        while read < maximumBytes, let chunk = try? handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            read += chunk.count
            carried.append(chunk)
            while let breakIndex = carried.firstIndex(of: 0x0A) {
                let line = carried[carried.startIndex..<breakIndex]
                carried = carried[carried.index(after: breakIndex)...]
                guard line.count <= maximumLineBytes, !line.isEmpty else { continue }
                let text = String(decoding: line, as: UTF8.self)
                guard text.contains(marker) else { continue }
                if let found = labelFromCommands(in: text) { newest = found }
            }
            if carried.count > maximumLineBytes { carried.removeAll(keepingCapacity: true) }
        }
        if !carried.isEmpty, carried.count <= maximumLineBytes {
            let text = String(decoding: carried, as: UTF8.self)
            if text.contains(marker), let found = labelFromCommands(in: text) { newest = found }
        }
        return newest
    }

    static func tagged(_ tag: String, in content: String) -> String? {
        guard let open = content.range(of: "<\(tag)>"),
              let close = content.range(of: "</\(tag)>", range: open.upperBound..<content.endIndex)
        else { return nil }
        return String(content[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSlug(_ text: String) -> Bool {
        guard text.count <= maximumLength, text.contains("-") else { return false }
        return text.range(of: "^[A-Za-z0-9]+(-[A-Za-z0-9]+)+$", options: .regularExpression) != nil
    }

    // MARK: - The model fallback

    /// What the model is asked. Deliberately narrow: the failure to avoid is a tab that reads
    /// `atlas` being replaced by a tab that reads `the atlas repository`.
    public static func prompt(excerpt: String) -> String {
        """
        Name this coding session in at most four words, describing the work being done — never the \
        repository, folder or tool. Reply with the name alone: no quotes, no punctuation, no \
        explanation. If the excerpt does not say what the work is, reply with the single word NONE.

        Session excerpt:
        \(excerpt)
        """
    }

    /// Whatever the model said, reduced to something safe to paint on a terminal tab — or nothing.
    ///
    /// Refusing is a real outcome and the common one worth getting right: a tab that keeps its
    /// folder name is merely unhelpful, while a tab showing an apology, an escape sequence or a
    /// paragraph is worse than what it replaced.
    public static func sanitize(_ raw: String) -> String? {
        let firstLine = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var text = String(firstLine.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        for quote in ["\"", "'", "“", "”", "`"] where text.hasPrefix(quote) && text.hasSuffix(quote) && text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty, text.uppercased() != "NONE",
              text.count <= maximumLength, words.count <= maximumWords else { return nil }
        return text
    }

    // MARK: - Which tabs to touch

    /// Whether a tab is still showing its folder name, and so has nothing to lose.
    ///
    /// The comparison forgives case and surrounding space because a terminal is free to change
    /// both, and a tab reading ` Atlas ` for the folder `atlas` has not been named by anyone.
    public static func needsName(current: String?, folder: String) -> Bool {
        guard let current, !current.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return normalized(current) == normalized(folder)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
