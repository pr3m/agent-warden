import Foundation

/// The two pieces of `SessionNamer` that touch the outside world: reading a slice of a transcript,
/// and asking a model to name it.
///
/// Kept apart from the policy so the policy can be tested without spawning anything, and kept apart
/// from `SessionNaming` so the pure rule stays pure.
public enum SessionNameAsk {
    /// How much of a transcript a model is shown.
    ///
    /// A tail, unlike the command rule's whole-file scan, and for the opposite reason: the question
    /// is "what is this session doing", and the newest exchanges answer it. Small on purpose — the
    /// prompt is read by a model that costs money and time per token, and four words do not need
    /// four thousand.
    public static let excerptBytes = 24 * 1024
    public static let excerptCharacters = 4_000

    /// Recent user prose from a transcript, with everything that is not prose left out.
    ///
    /// Only user messages, because they say what was *asked for*; assistant turns are long, and a
    /// session's own narration of its work is a worse summary than the request that started it.
    /// Tool output, thinking and pasted blobs never appear — the same discipline
    /// `TranscriptMetadata` applies, for the same reason: this text leaves the machine.
    ///
    /// **It reads from the front, not the tail, and that is the opposite of every other reader
    /// here.** Measured on a real finished session, the last 24 KB held `/exit`, a `See ya!` and
    /// four attachment records — true, recent, and no use at all for saying what the session was
    /// *for*. What a session is about is established when somebody asks for it. So this takes the
    /// earliest prose and, if that runs short, keeps reading forward.
    public static func excerpt(of url: URL, limit: Int = excerptBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var lines: [String] = []
        var carried = Data()
        var read = 0
        let maximumLineBytes = 512 * 1024
        let bounded = min(max(limit, 4096), 4 * 1024 * 1024)

        func take(_ line: Data) {
            guard line.count <= maximumLineBytes, line.first == 0x7B else { return }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any] else { return }
            // Content is a bare string for a typed prompt and an array of blocks once anything is
            // attached. Both carry prose; only the string case was handled at first, and on a real
            // transcript that silently produced nothing at all.
            var prose = ""
            if let text = message["content"] as? String {
                prose = text
            } else if let blocks = message["content"] as? [[String: Any]] {
                prose = blocks.compactMap { block in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }.joined(separator: " ")
            }
            let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
            // Harness chatter, hook output, command envelopes and replayed results are not what
            // anyone typed, and a session that opens with one would otherwise be named after it.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), trimmed.count > 8 else { return }
            lines.append(String(trimmed.prefix(300)))
        }

        while lines.count < 12, read < bounded,
              let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            read += chunk.count
            carried.append(chunk)
            while let breakIndex = carried.firstIndex(of: 0x0A) {
                take(Data(carried[carried.startIndex..<breakIndex]))
                carried = carried[carried.index(after: breakIndex)...]
            }
            if carried.count > maximumLineBytes { carried.removeAll(keepingCapacity: true) }
        }
        guard !lines.isEmpty else { return nil }
        return String(lines.joined(separator: "\n").prefix(excerptCharacters))
    }

    /// Ask the CLI for a name, once, with a deadline.
    ///
    /// `--print` with no tools and no MCP: this is a question about text, and a naming pass that
    /// could read files or run commands would be a far larger thing than its purpose. Returns nil
    /// on every failure — not installed, timed out, non-zero, empty — because a tab that keeps its
    /// folder name is the correct outcome of a failed naming attempt.
    ///
    /// **`--bare` is not an optimisation, it is the thing that stops this eating its own output.**
    /// Without it the naming call starts a session like any other, fires the user's SessionStart
    /// hooks, and warden's hook claims the terminal for the new session — which *drops that tab's
    /// custom label*, the very thing this function exists to produce. Observed: a probe run wiped
    /// the label off the tab it was launched from, and left four junk sessions in the fleet reading
    /// "Name this coding session in at most four words". Skipping hooks makes the call invisible to
    /// everything that watches sessions, which is what a naming pass should be.
    ///
    /// **The `--` is load-bearing.** `--mcp-config` takes a value, so without a terminator the
    /// prompt is eaten as its argument and the CLI reports a missing config *file* named after the
    /// first line of the prompt — with exit status 0, so it reads as an empty answer rather than a
    /// mistake. The CLI also warns on stderr about connectors when an API key is set; only stdout
    /// is read, so that never reaches a tab.
    public static func askModel(prompt: String,
                                executable: String = ClaudeStreamLauncher.defaultExecutable,
                                model: String = "claude-haiku-4-5-20251001",
                                timeout: TimeInterval = 30) -> String? {
        let outcome = BoundedProcess.run(
            executable: executable,
            arguments: ["--bare", "--print", "--model", model,
                        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                        "--tools", "", "--", prompt],
            timeout: timeout,
            maximumOutputBytes: 4 * 1024)
        guard !outcome.launchFailed, !outcome.timedOut, outcome.status == 0 else { return nil }
        let answer = String(decoding: outcome.stdout, as: UTF8.self)
        return answer.isEmpty ? nil : answer
    }
}
