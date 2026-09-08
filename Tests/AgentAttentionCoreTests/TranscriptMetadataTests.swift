import Foundation
import Testing
@testable import AgentAttentionCore

/// Reading the current working directory out of a session transcript.
///
/// Transcripts are large (tens of megabytes) and contain prompts, tool output and whatever the user
/// pasted. Two rules follow: read a bounded tail rather than the file, and extract three scalar
/// fields — never a message body, never anything logged.
@Suite("Transcript metadata")
final class TranscriptMetadataTests {
    private let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-warden-transcript-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func line(cwd: String, branch: String? = nil, session: String = "s1", secret: String = "SECRET") -> String {
        var object: [String: Any] = [
            "type": "user",
            "sessionId": session,
            "cwd": cwd,
            "timestamp": "2026-09-06T08:00:00.000Z",
            // Everything below must never be read out of the file.
            "message": ["role": "user", "content": secret],
            "toolUseResult": secret,
        ]
        if let branch { object["gitBranch"] = branch }
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func write(_ lines: [String], name: String = "s1.jsonl", prefixBytes: Int = 0) throws -> URL {
        let url = root.appendingPathComponent(name)
        var text = String(repeating: "x", count: prefixBytes)
        if prefixBytes > 0 { text += "\n" }
        text += lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("The newest cwd wins")
    func latestCwd() throws {
        let url = try write([
            line(cwd: "/Users/dev/code/redmy"),
            line(cwd: "/Users/dev/code/redmy/worktrees/sensitivity-train", branch: "sensitivity-train"),
        ])
        let summary = TranscriptMetadata.tail(of: url)
        #expect(summary.cwd == "/Users/dev/code/redmy/worktrees/sensitivity-train")
        #expect(summary.gitBranch == "sensitivity-train")
        #expect(summary.sessionID == "s1")
    }

    @Test("Only a bounded tail is read, however large the file")
    func boundedRead() throws {
        // A megabyte of transcript with the answer in the last few hundred bytes.
        let url = try write([line(cwd: "/Users/dev/code/latest")], prefixBytes: 1_048_576)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        #expect(size.intValue > TranscriptMetadata.tailBytes)

        let summary = TranscriptMetadata.tail(of: url)
        #expect(summary.cwd == "/Users/dev/code/latest")
        #expect(summary.bytesRead <= TranscriptMetadata.tailBytes)
    }

    @Test("A cwd that fell outside the tail window is simply not found")
    func answerOutsideTheWindow() throws {
        // Honest emptiness beats reading the whole file to be sure.
        var lines = [line(cwd: "/Users/dev/code/ancient")]
        lines += (0..<400).map { _ in String(repeating: "y", count: 512) }
        let url = try write(lines)
        #expect(TranscriptMetadata.tail(of: url).cwd == nil)
    }

    @Test("The partial first line of the window is discarded, not misparsed")
    func partialFirstLine() throws {
        // Slicing mid-line leaves a fragment that could parse into something wrong; drop it.
        let good = line(cwd: "/Users/dev/code/good")
        let padding = String(repeating: "z", count: TranscriptMetadata.tailBytes)
        let url = root.appendingPathComponent("partial.jsonl")
        try Data((padding + "{\"cwd\":\"/Users/dev/code/tru" + "\n" + good + "\n").utf8).write(to: url)

        #expect(TranscriptMetadata.tail(of: url).cwd == "/Users/dev/code/good")
    }

    @Test("Nothing but cwd, branch and session id comes back")
    func nothingElseIsExtracted() throws {
        let url = try write([line(cwd: "/Users/dev/code/alpha", secret: "SECRET-PROMPT-BODY")])
        let summary = TranscriptMetadata.tail(of: url)

        let mirrored = "\(summary)"
        #expect(!mirrored.contains("SECRET-PROMPT-BODY"), "message bodies never leave the file")
        #expect(summary.cwd == "/Users/dev/code/alpha")
    }

    @Test("Garbage, empty files and missing files all yield nothing")
    func degradesQuietly() throws {
        let garbage = try write(["not json at all", "", "{", "[1,2,3]"], name: "garbage.jsonl")
        #expect(TranscriptMetadata.tail(of: garbage).cwd == nil)

        let empty = root.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        #expect(TranscriptMetadata.tail(of: empty).cwd == nil)

        #expect(TranscriptMetadata.tail(of: root.appendingPathComponent("missing.jsonl")).cwd == nil)
    }

    @Test("A record for a different session is ignored")
    func wrongSessionIgnored() throws {
        let url = try write([line(cwd: "/Users/dev/code/other", session: "other-session")])
        #expect(TranscriptMetadata.tail(of: url, expecting: "s1").cwd == nil)
        #expect(TranscriptMetadata.tail(of: url, expecting: "other-session").cwd == "/Users/dev/code/other")
    }

    @Test("The transcript is found from the launch directory Claude Code records")
    func locatingTheTranscript() throws {
        let projects = root.appendingPathComponent("projects")
        let slug = "-Users-christjanschumann-dev-redmy"
        try FileManager.default.createDirectory(at: projects.appendingPathComponent(slug),
                                                withIntermediateDirectories: true)
        let transcript = projects.appendingPathComponent("\(slug)/sess-1.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        #expect(TranscriptMetadata.locate(sessionID: "sess-1",
                                          cwd: "/Users/christjanschumann/dev/redmy",
                                          projectsRoot: projects) == transcript)
        #expect(TranscriptMetadata.locate(sessionID: "missing",
                                          cwd: "/Users/christjanschumann/dev/redmy",
                                          projectsRoot: projects) == nil)
        // Without a cwd to build the slug from, a bounded search still finds it.
        #expect(TranscriptMetadata.locate(sessionID: "sess-1", cwd: nil, projectsRoot: projects) == transcript)
    }

    @Test("Enrichment never replaces a directory the hook already reported")
    func enrichmentNeverOverwritesNewer() throws {
        // The transcript tail is older evidence than a live hook. It fills a blank; it never argues.
        var identity = SessionIdentity(sessionID: "s1", cwd: "/Users/dev/code/from-hook")
        identity.enrich(withTranscriptCwd: "/Users/dev/code/from-transcript", gitBranch: "main")
        #expect(identity.cwd == "/Users/dev/code/from-hook")
        #expect(identity.gitBranch == "main", "a field it had nothing for is filled")

        var blank = SessionIdentity(sessionID: "s1", cwd: "")
        blank.enrich(withTranscriptCwd: "/Users/dev/code/from-transcript", gitBranch: nil)
        #expect(blank.cwd == "/Users/dev/code/from-transcript")
    }
}

@Suite("Discovery enrichment")
struct DiscoveryEnrichmentTests {
    private var discovered: DiscoveredSession {
        let record = RegistryRecord(sessionID: "s1", pid: 4242, cwd: "/Users/dev/code/redmy")
        return DiscoveredSession(record: record, identity: record.sessionIdentity())
    }

    @Test("The transcript's working directory beats the launch directory")
    func transcriptWinsOverRegistry() {
        // The registry says where `claude` was started; the transcript says where it is now. For a
        // session in a worktree those differ, and the worktree is the useful label.
        let enriched = discovered.enriched(withTranscript: .init(
            cwd: "/Users/dev/code/redmy/worktrees/sensitivity-train", gitBranch: "sensitivity-train"))
        #expect(enriched.identity.cwd == "/Users/dev/code/redmy/worktrees/sensitivity-train")
        #expect(enriched.identity.gitBranch == "sensitivity-train")
        #expect(enriched.record.cwd == "/Users/dev/code/redmy", "the record itself is not rewritten")
    }

    @Test("An empty transcript changes nothing")
    func emptyTranscriptIsHarmless() {
        let enriched = discovered.enriched(withTranscript: .init())
        #expect(enriched.identity.cwd == "/Users/dev/code/redmy")
        #expect(enriched.identity.gitBranch == nil)
    }
}
