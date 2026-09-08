import Foundation

/// A read-only, on-demand look at what one session has recently been talking about.
///
/// This is the one place in the app that reads message content, and it exists under tight rules:
///
/// - **Only when asked.** Nothing here runs on a timer, on a hook, or during monitoring. Content is
///   produced in response to an explicit query and returned to that caller. It is never folded into
///   the queue, never written to `state.json`, never logged.
/// - **Only the session you named.** The transcript is located by *full* session id, and every
///   record is checked to carry that same id. A file belonging to another session is skipped, not
///   believed. Getting the wrong conversation would be worse than getting none.
/// - **Excerpts, attributed.** What comes back is recent user and assistant text with timestamps —
///   what was actually said, and by whom. It is not a summary, and nothing about it is generated.
/// - **Nothing that is not conversation.** Thinking blocks, tool inputs, tool result payloads and
///   attachments are dropped. They are where pasted secrets and large blobs live.
/// - **Bounded.** A tail of at most 1 MiB, a fixed number of messages, a per-excerpt cap and a total
///   cap. Transcripts run to tens of megabytes and are being appended to while we read.
/// - **It is not evidence.** Nothing read here may raise an attention item, clear one, or change a
///   session's state. The queue is built from hooks and only from hooks.
public struct SessionContext: Codable, Sendable, Equatable {
    /// One thing that was said.
    public struct Message: Codable, Sendable, Equatable {
        /// "user" or "assistant". Attributed, never merged.
        public var role: String
        public var at: Date?
        public var excerpt: String
        /// True when the excerpt is shorter than what was said.
        public var truncated: Bool

        public init(role: String, at: Date?, excerpt: String, truncated: Bool) {
            self.role = role
            self.at = at
            self.excerpt = excerpt
            self.truncated = truncated
        }
    }

    /// A structured question the session asked, with its options as they were written.
    public struct Question: Codable, Sendable, Equatable {
        public var question: String
        public var options: [String]
        public var askedAt: Date?
        /// What the transcript positively shows about this question, and nothing more:
        ///
        /// - `answered` — a matching `tool_result` for this exact `tool_use_id`, not an error.
        /// - `cancelled` — a matching `tool_result` marked `is_error`. The question was interrupted
        ///   or refused; that is not an answer, and it is not "still waiting" either.
        /// - `notObserved` — no matching result in the part we read. It may be outside the window,
        ///   it may never have been written. Either way we did not see it, and *not seeing an
        ///   answer is not evidence that one is owed*. Only a live hook can say a session is
        ///   waiting, and that is reported separately.
        public var answered: String
        /// True only when a result was positively found. Absence never sets it.
        public var correlationComplete: Bool

        public init(question: String, options: [String], askedAt: Date?, answered: String, correlationComplete: Bool) {
            self.question = question
            self.options = options
            self.askedAt = askedAt
            self.answered = answered
            self.correlationComplete = correlationComplete
        }
    }

    /// Why there is nothing to show.
    public enum Availability: String, Codable, Sendable, Error {
        case read
        /// No transcript file exists for that session id.
        case noTranscript
        /// The file exists but could not be opened.
        case denied
        /// The path resolved somewhere we will not follow.
        case rejectedPath
        /// The session id is not one we know about.
        case unknownSession
    }

    public var sessionID: String
    public var availability: Availability
    public var transcriptPath: String?
    /// When this was read. Everything below is a statement about that moment and no other.
    public var readAt: Date
    public var bytesRead: Int
    /// True when the transcript is longer than the tail we read — there is more, further back.
    public var tailTruncated: Bool
    public var messages: [Message]
    /// The most recent thing the person actually typed, as opposed to a tool result.
    public var latestUserRequest: Message?
    public var latestAssistantResponse: Message?
    public var questions: [Question]
    /// Plain sentences about anything that limits the above.
    public var notes: [String]

    public init(
        sessionID: String,
        availability: Availability,
        transcriptPath: String? = nil,
        readAt: Date,
        bytesRead: Int = 0,
        tailTruncated: Bool = false,
        messages: [Message] = [],
        latestUserRequest: Message? = nil,
        latestAssistantResponse: Message? = nil,
        questions: [Question] = [],
        notes: [String] = []
    ) {
        self.sessionID = sessionID
        self.availability = availability
        self.transcriptPath = transcriptPath
        self.readAt = readAt
        self.bytesRead = bytesRead
        self.tailTruncated = tailTruncated
        self.messages = messages
        self.latestUserRequest = latestUserRequest
        self.latestAssistantResponse = latestAssistantResponse
        self.questions = questions
        self.notes = notes
    }
}

// MARK: - Reading it

public enum SessionContextReader {
    /// The tail we are willing to read. Transcripts reach tens of megabytes.
    public static let maximumTailBytes = 1024 * 1024
    /// How many recent messages come back.
    public static let maximumMessages = 20
    /// Per-excerpt cap, and the cap on all of them together.
    public static let maximumExcerptCharacters = 600
    public static let maximumTotalCharacters = 12_000

    /// Find the transcript for a session id, under `<claudeHome>/projects/*/<id>.jsonl`.
    ///
    /// The id must be the full one. Short ids collide, and a collision here means showing somebody
    /// another session's conversation.
    public static func locateTranscript(sessionID: String, claudeHome: URL) -> Result<URL, SessionContext.Availability> {
        guard isPlausibleSessionID(sessionID) else { return .failure(.unknownSession) }
        let projects = claudeHome.appendingPathComponent("projects", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return .failure(.noTranscript) }

        for directory in entries {
            let candidate = directory.appendingPathComponent("\(sessionID).jsonl")
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            return validate(candidate, under: projects)
        }
        return .failure(.noTranscript)
    }

    /// A transcript has to be a regular file that really lives under the projects directory.
    ///
    /// Resolving symlinks first is the point: a link pointing at `~/.ssh/id_ed25519`, or at a device,
    /// must not be read just because it was placed where a transcript goes.
    static func validate(_ url: URL, under root: URL) -> Result<URL, SessionContext.Availability> {
        let resolved = url.resolvingSymlinksInPath()
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.standardizedFileURL.path.hasPrefix(rootPath + "/") else { return .failure(.rejectedPath) }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let type = attributes[.type] as? FileAttributeType else { return .failure(.denied) }
        guard type == .typeRegular else { return .failure(.rejectedPath) }
        guard FileManager.default.isReadableFile(atPath: resolved.path) else { return .failure(.denied) }
        return .success(resolved)
    }

    /// A session id is a UUID. Anything else never becomes a path component.
    public static func isPlausibleSessionID(_ id: String) -> Bool {
        guard id.count >= 8, id.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
    }

    /// Read the tail of one session's transcript. Blocking; callers run it off the main thread.
    public static func read(
        sessionID: String,
        claudeHome: URL,
        now: Date = Date(),
        tailBytes: Int = maximumTailBytes
    ) -> SessionContext {
        switch locateTranscript(sessionID: sessionID, claudeHome: claudeHome) {
        case .failure(let why):
            return SessionContext(sessionID: sessionID, availability: why, readAt: now,
                                  notes: [note(for: why)])
        case .success(let url):
            return read(url: url, sessionID: sessionID, now: now, tailBytes: tailBytes)
        }
    }

    public static func note(for availability: SessionContext.Availability) -> String {
        switch availability {
        case .noTranscript: return "No transcript file exists for this session id."
        case .denied: return "The transcript exists but could not be opened."
        case .rejectedPath: return "That path does not resolve to a transcript file and was not read."
        case .unknownSession: return "That is not a session id this app recognises."
        case .read: return ""
        }
    }

    public static func read(url: URL, sessionID: String, now: Date = Date(), tailBytes: Int = maximumTailBytes) -> SessionContext {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return SessionContext(sessionID: sessionID, availability: .denied, transcriptPath: url.path,
                                  readAt: now, notes: [note(for: .denied)])
        }
        defer { try? handle.close() }

        let total = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        let bounded = min(max(tailBytes, 4096), maximumTailBytes)
        let offset = max(0, total - bounded)
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        // Not `readToEnd`: the file is being appended to while we look, and "to the end" of a
        // growing transcript is not a bounded read.
        let data = (try? handle.read(upToCount: bounded)) ?? Data()

        var text = String(decoding: data, as: UTF8.self)
        var notes: [String] = []
        if offset > 0 {
            // The window opens mid-line. Half a record can still parse as something; drop it.
            guard let firstNewline = text.firstIndex(of: "\n") else {
                return SessionContext(sessionID: sessionID, availability: .read, transcriptPath: url.path,
                                      readAt: now, bytesRead: data.count, tailTruncated: true,
                                      notes: ["The last \(bounded) bytes contain no complete record."])
            }
            text = String(text[text.index(after: firstNewline)...])
            notes.append("Read the last \(bounded / 1024) KiB of a \(total / 1024) KiB transcript; anything older is not shown.")
        }

        var parsed = Parse(sessionID: sessionID)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            parsed.consume(line: line)
        }

        if parsed.foreignRecords > 0 {
            notes.append("\(parsed.foreignRecords) record(s) in that file belong to another session and were skipped.")
        }
        if parsed.malformed > 0 {
            notes.append("\(parsed.malformed) record(s) could not be parsed and were skipped.")
        }

        let messages = Array(parsed.messages.suffix(maximumMessages))
        return SessionContext(
            sessionID: sessionID,
            availability: .read,
            transcriptPath: url.path,
            readAt: now,
            bytesRead: data.count,
            tailTruncated: offset > 0,
            messages: capTotal(messages),
            latestUserRequest: parsed.messages.last { $0.role == "user" },
            latestAssistantResponse: parsed.messages.last { $0.role == "assistant" },
            questions: parsed.resolvedQuestions(),
            notes: notes
        )
    }

    /// Keep the whole reply under a total budget, oldest first.
    static func capTotal(_ messages: [SessionContext.Message]) -> [SessionContext.Message] {
        var budget = maximumTotalCharacters
        var kept: [SessionContext.Message] = []
        for message in messages.reversed() {
            guard budget > 0 else { break }
            var copy = message
            if copy.excerpt.count > budget {
                copy.excerpt = String(copy.excerpt.prefix(max(0, budget - 1))) + "…"
                copy.truncated = true
            }
            budget -= copy.excerpt.count
            kept.append(copy)
        }
        return kept.reversed()
    }

    // MARK: - One pass over the tail

    struct Parse {
        let sessionID: String
        var messages: [SessionContext.Message] = []
        var pendingQuestions: [(id: String, question: SessionContext.Question)] = []
        /// What we saw come back for a `tool_use_id`. Absence is not an entry.
        enum ResultOutcome { case answered, cancelled }
        var resultOutcomes: [String: ResultOutcome] = [:]
        var foreignRecords = 0
        var malformed = 0

        mutating func consume(line: Substring) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                malformed += 1
                return
            }
            // Every record has to *name* the session we asked for. A record with no `sessionId` at
            // all is not implicitly ours: a transcript file can be edited, appended to or misfiled,
            // and "no id" would then be a way to get arbitrary text attributed to this session.
            // Positive identity or nothing.
            guard let recordSession = record["sessionId"] as? String, recordSession == sessionID else {
                foreignRecords += 1
                return
            }
            // A sidechain is a subagent's own conversation, not this session's.
            if record["isSidechain"] as? Bool == true { return }

            let type = record["type"] as? String
            guard type == "user" || type == "assistant" else { return }
            guard let message = record["message"] as? [String: Any] else { return }

            // A `user` record is not automatically something a person typed. Claude Code writes tool
            // results, injected system notices and compaction summaries with the same role. Only an
            // external prompt with no tool payload is a genuine request.
            if type == "user", !Parse.isGenuineUserRecord(record) { return }

            // `content` comes in two shapes. The list of typed blocks is the common one; a plain
            // string is the other, and it is what a short typed prompt often looks like. Both are
            // real conversation and both were observed in a live transcript.
            let blocks: [[String: Any]]
            if let typed = message["content"] as? [[String: Any]] {
                blocks = typed
            } else if let plain = message["content"] as? String, !plain.isEmpty {
                blocks = [["type": "text", "text": plain]]
            } else {
                return
            }

            let at = (record["timestamp"] as? String).flatMap(JSONCoding.dateFormatter.date(from:))
                ?? (record["timestamp"] as? String).flatMap(ISO8601DateFormatter().date(from:))

            var spoken: [String] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    // The only kind of block that is conversation.
                    if let text = block["text"] as? String, !text.isEmpty { spoken.append(text) }
                case "tool_use":
                    if (block["name"] as? String) == "AskUserQuestion",
                       let id = block["id"] as? String,
                       let input = block["input"] as? [String: Any] {
                        for question in askedQuestions(from: input, at: at) {
                            pendingQuestions.append((id: id, question: question))
                        }
                    }
                case "tool_result":
                    // Never the payload — only whether this `tool_use` got a result, and whether
                    // that result was an error. A cancelled or refused question is not an answer.
                    if let id = block["tool_use_id"] as? String {
                        let failed = (block["is_error"] as? Bool) == true
                        resultOutcomes[id] = failed ? .cancelled : .answered
                    }
                default:
                    // `thinking`, `image`, anything new: not conversation, not shown.
                    break
                }
            }

            guard !spoken.isEmpty else { return }
            let joined = spoken.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { return }
            let truncated = joined.count > maximumExcerptCharacters
            messages.append(SessionContext.Message(
                role: type == "user" ? "user" : "assistant",
                at: at,
                excerpt: truncated ? String(joined.prefix(maximumExcerptCharacters - 1)) + "…" : joined,
                truncated: truncated
            ))
        }

        /// `AskUserQuestion` input, as written. Nothing is inferred about the answer here.
        func askedQuestions(from input: [String: Any], at moment: Date?) -> [SessionContext.Question] {
            guard let raw = input["questions"] as? [[String: Any]] else { return [] }
            return raw.compactMap { entry in
                guard let question = entry["question"] as? String, !question.isEmpty else { return nil }
                let options: [String] = (entry["options"] as? [Any] ?? []).compactMap { option in
                    if let text = option as? String { return text }
                    if let dictionary = option as? [String: Any] {
                        return (dictionary["label"] as? String) ?? (dictionary["value"] as? String)
                    }
                    return nil
                }
                return SessionContext.Question(
                    question: String(question.prefix(400)),
                    options: options.prefix(10).map { String($0.prefix(120)) },
                    askedAt: moment,
                    answered: "unknown",
                    correlationComplete: false
                )
            }
        }

        /// Correlate each question with a `tool_result` carrying the same `tool_use_id`.
        ///
        /// Only a result we positively saw says anything. An error result means the question was
        /// cancelled or refused — not answered, and not outstanding either. **No result at all is
        /// `notObserved`**, even when we read the whole file: a transcript is not a record of what
        /// a session is waiting for, and treating a missing line as a pending request would be
        /// exactly the invented alert this app exists to avoid. Whether a session is actually
        /// waiting comes from a hook, is reported separately, and dominates.
        func resolvedQuestions() -> [SessionContext.Question] {
            pendingQuestions.suffix(5).map { entry in
                var question = entry.question
                switch resultOutcomes[entry.id] {
                case .answered:
                    question.answered = "answered"
                    question.correlationComplete = true
                case .cancelled:
                    question.answered = "cancelled"
                    question.correlationComplete = true
                case nil:
                    question.answered = "notObserved"
                    question.correlationComplete = false
                }
                return question
            }
        }

        /// Did a person type this, or did the client write it?
        ///
        /// `toolUseResult` marks a tool's output being fed back in. `isMeta` and compaction summaries
        /// are the client talking to itself. `userType` is `external` for a real prompt. Any of those
        /// would otherwise be reported as "the latest thing you asked for".
        static func isGenuineUserRecord(_ record: [String: Any]) -> Bool {
            if record["toolUseResult"] != nil { return false }
            if (record["isMeta"] as? Bool) == true { return false }
            if (record["isCompactSummary"] as? Bool) == true { return false }
            if let kind = record["userType"] as? String, kind != "external" { return false }
            return true
        }
    }
}
