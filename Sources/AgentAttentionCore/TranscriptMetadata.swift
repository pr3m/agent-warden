import Foundation

/// Pulls the current working directory out of a session transcript, and nothing else.
///
/// The registry records where a session was *launched*. A session that has since moved into a
/// worktree is still listed under its launch directory, which is the wrong label to show. The
/// transcript's most recent line knows better.
///
/// Two constraints shape everything here. Transcripts run to tens of megabytes, so only a bounded
/// tail is read — never the file. And they contain prompts, tool output and whatever was pasted
/// into them, so exactly three scalar fields are extracted: `cwd`, `gitBranch` and `sessionId`.
/// Message bodies are never returned, never logged and never kept.
public enum TranscriptMetadata {
    /// Enough for a few dozen recent lines; small enough to read on a background pass without
    /// noticing. A cwd older than this window is simply not found.
    public static let tailBytes = 64 * 1024

    public struct Summary: Sendable, Equatable, CustomStringConvertible {
        public var cwd: String?
        public var gitBranch: String?
        public var sessionID: String?
        public var bytesRead: Int

        public init(cwd: String? = nil, gitBranch: String? = nil, sessionID: String? = nil, bytesRead: Int = 0) {
            self.cwd = cwd
            self.gitBranch = gitBranch
            self.sessionID = sessionID
            self.bytesRead = bytesRead
        }

        /// Spelled out so an accidental log line cannot smuggle anything else out.
        public var description: String {
            "TranscriptSummary(cwd: \(cwd ?? "-"), branch: \(gitBranch ?? "-"), session: \(sessionID ?? "-"))"
        }
    }

    /// Read the last `tailBytes` and return the newest cwd found.
    ///
    /// `expecting` guards against a transcript that has been reused or misfiled: a line belonging
    /// to another session is ignored rather than believed.
    public static func tail(of url: URL, expecting sessionID: String? = nil, limit: Int = tailBytes) -> Summary {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Summary() }
        defer { try? handle.close() }

        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue > 0 else { return Summary() }

        let bounded = min(max(limit, 1024), 1 * 1024 * 1024)   // sane whatever a caller passes
        let total = size.intValue
        let offset = max(0, total - bounded)
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        // `read(upToCount:)` rather than `readToEnd`: the file is being appended to while we look,
        // and "read to the end" of a growing transcript is not a bounded read.
        guard let data = try? handle.read(upToCount: bounded), !data.isEmpty else { return Summary() }

        var text = String(decoding: data, as: UTF8.self)
        if offset > 0 {
            // The window starts mid-line. A fragment can still look like JSON, so drop it rather
            // than risk parsing half a record — and if no newline fits in the window at all, there
            // is no whole record here to read.
            guard let firstBreak = text.firstIndex(of: "\n") else { return Summary(bytesRead: data.count) }
            text = String(text[text.index(after: firstBreak)...])
        }

        var summary = Summary(bytesRead: data.count)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.first == "{" else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }

            if let expected = sessionID {
                guard let recorded = object["sessionId"] as? String, recorded == expected else { continue }
            }
            // Three fields. Nothing else is even looked at.
            if let cwd = object["cwd"] as? String, !cwd.isEmpty {
                summary.cwd = cwd
                summary.gitBranch = (object["gitBranch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                summary.sessionID = (object["sessionId"] as? String) ?? summary.sessionID
            }
        }
        return summary
    }

    /// Find a session's transcript.
    ///
    /// Claude Code files transcripts under a slug of the launch directory, so the registry's `cwd`
    /// usually points straight at it. Without one, fall back to a bounded search rather than
    /// walking the whole tree.
    public static func locate(sessionID: String, cwd: String?, projectsRoot: URL, searchLimit: Int = 400) -> URL? {
        let fm = FileManager.default
        let file = "\(EventStore.safeFileName(sessionID)).jsonl"

        if let cwd, !cwd.isEmpty {
            let direct = projectsRoot.appendingPathComponent(slug(for: cwd)).appendingPathComponent(file)
            if fm.fileExists(atPath: direct.path) { return direct }
        }

        guard let directories = try? fm.contentsOfDirectory(atPath: projectsRoot.path) else { return nil }
        for name in directories.sorted().prefix(searchLimit) {
            let candidate = projectsRoot.appendingPathComponent(name).appendingPathComponent(file)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// "/Users/dev/code/atlas" → "-Users-dev-code-atlas"
    static func slug(for path: String) -> String {
        var slug = path.replacingOccurrences(of: "/", with: "-")
        slug = slug.replacingOccurrences(of: ".", with: "-")
        return slug
    }
}
