import Foundation

/// What a `Stop` hook said about work still running behind the turn.
///
/// The `Stop` payload documents two arrays — `background_tasks` and `session_crons` — which are
/// present when the task registry is reachable. That is a structured answer to a question this app
/// previously had no way to ask: did the turn *finish*, or did it hand off to something and pause?
///
/// **Both arrays are required for a confident answer.** `session_crons` carries scheduled wakeups,
/// which are pending work just as much as a running shell is. An empty task list with a cron
/// scheduled is not a finished turn, and a *missing* cron list means the registry was not fully
/// readable — so it cannot be a finished turn either. Treating either as completion is exactly the
/// false "work complete" this type exists to prevent.
///
/// Only counts are kept. Entries carry `description`, `command` and `prompt` fields; none of that is
/// session content we have any business persisting, so none of it is read.
///
/// **Nothing here is guessed.** A status string we do not recognise makes the whole reading
/// uncertain rather than being filed under "running" or "done" — an unknown vocabulary must not
/// become a confident claim in either direction.
public struct BackgroundEvidence: Codable, Sendable, Equatable {
    public enum Availability: String, Codable, Sendable {
        /// Both arrays read cleanly, and something is still pending — a running task, a scheduled
        /// wakeup, or both.
        case reported
        /// Both arrays read cleanly and everything in them is finished. The **only** shape that can
        /// support a claim of completion.
        case none
        /// A field was missing, the wrong shape, malformed, or carried a status we do not
        /// recognise. Neither busy nor finished.
        case unknown
    }

    public var availability: Availability
    public var running: Int
    public var completed: Int
    public var failed: Int
    /// Statuses we could not classify. Any at all makes the reading uncertain.
    public var unrecognised: Int
    /// Scheduled wakeups. Pending work, and counted as such.
    public var crons: Int
    /// Task types seen (`shell`, `subagent`, `monitor`, …). Vocabulary, not content.
    public var types: [String]
    public var observedAt: Date
    /// One bounded record per entry: its identifier, its type, what it said its status was, and —
    /// for a scheduled wakeup — whether it recurs.
    ///
    /// **Identifiers and vocabulary only.** Entries also carry `command`, `description` and
    /// `prompt`; none of that is session content this app has any business keeping, so none of it
    /// is read. What these buy is the ability to say *which* job, rather than only how many.
    public var records: [SnapshotRecord]
    /// How well the records describe the list. Never "all of it": an entry without an id, a
    /// repeated id, or a list longer than the cap all mean the account is partial.
    public var recordCoverage: BackgroundRegistry.Coverage

    /// A single entry, reduced to what can be shown without quoting anybody.
    public struct SnapshotRecord: Codable, Sendable, Equatable {
        public var id: String?
        public var type: String?
        public var state: BackgroundJob.State
        public var kind: BackgroundJob.Kind
        public var recurring: Bool?

        public init(id: String?, type: String?, state: BackgroundJob.State,
                    kind: BackgroundJob.Kind, recurring: Bool? = nil) {
            self.id = id
            self.type = type
            self.state = state
            self.kind = kind
            self.recurring = recurring
        }
    }

    /// Records kept per snapshot. Counts are not capped — only the per-job detail is.
    public static let maximumRecords = 32

    public init(
        availability: Availability,
        running: Int = 0,
        completed: Int = 0,
        failed: Int = 0,
        unrecognised: Int = 0,
        crons: Int = 0,
        types: [String] = [],
        observedAt: Date,
        records: [SnapshotRecord] = [],
        recordCoverage: BackgroundRegistry.Coverage = .unknown
    ) {
        self.availability = availability
        self.running = running
        self.completed = completed
        self.failed = failed
        self.unrecognised = unrecognised
        self.crons = crons
        self.types = types
        self.observedAt = observedAt
        self.records = records
        self.recordCoverage = recordCoverage
    }

    /// Decoded leniently, so a snapshot written before per-job records existed still loads — and
    /// reads as `unknown` coverage rather than as an empty list of jobs, which would be a claim.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        availability = (try? c.decode(Availability.self, forKey: .availability)) ?? .unknown
        running = ((try? c.decodeIfPresent(Int.self, forKey: .running)) ?? nil) ?? 0
        completed = ((try? c.decodeIfPresent(Int.self, forKey: .completed)) ?? nil) ?? 0
        failed = ((try? c.decodeIfPresent(Int.self, forKey: .failed)) ?? nil) ?? 0
        unrecognised = ((try? c.decodeIfPresent(Int.self, forKey: .unrecognised)) ?? nil) ?? 0
        crons = ((try? c.decodeIfPresent(Int.self, forKey: .crons)) ?? nil) ?? 0
        types = ((try? c.decodeIfPresent([String].self, forKey: .types)) ?? nil) ?? []
        observedAt = (try? c.decode(Date.self, forKey: .observedAt)) ?? Date(timeIntervalSince1970: 0)
        records = ((try? c.decodeIfPresent([SnapshotRecord].self, forKey: .records)) ?? nil) ?? []
        recordCoverage = ((try? c.decodeIfPresent(BackgroundRegistry.Coverage.self,
                                                  forKey: .recordCoverage)) ?? nil)
            ?? (records.isEmpty ? .unknown : .partial)
    }

    /// A task we positively read as failed.
    ///
    /// This is the one thing that outranks everything else here. A turn that left a failed task
    /// behind must never be described as a successful completion, and it must stay actionable even
    /// while other tasks are still running — otherwise a real error hides behind a quiet pause.
    public var hasFailure: Bool { failed > 0 }

    /// Is something demonstrably still pending behind this turn, with nothing gone wrong?
    ///
    /// A scheduled wakeup counts: the session is not finished, it is waiting for a clock.
    public var isWaitingOnBackgroundWork: Bool {
        availability == .reported && !hasFailure
    }

    /// Did the turn demonstrably finish with nothing left behind?
    ///
    /// Only this counts as a confirmed milestone. Anything else — a missing or malformed array, an
    /// unfamiliar status, a pending cron, an older Claude Code that does not emit the fields — is a
    /// turn that ended without us being able to say it completed.
    public var isConfirmedComplete: Bool {
        availability == .none && !hasFailure
    }

    public func isStale(at now: Date, after ttl: TimeInterval) -> Bool {
        now.timeIntervalSince(observedAt) > ttl
    }

    /// Evidence we could not read at all.
    public static func unknown(at now: Date) -> BackgroundEvidence {
        BackgroundEvidence(availability: .unknown, observedAt: now)
    }

    // MARK: - Reading a Stop payload

    /// Statuses that mean "still going". Matched exactly — never by substring.
    static let runningStatuses: Set<String> = ["running", "in_progress", "pending", "queued", "active", "started"]
    static let completedStatuses: Set<String> = ["completed", "complete", "succeeded", "success", "done", "finished"]
    static let failedStatuses: Set<String> = ["failed", "error", "errored", "cancelled", "canceled", "timeout", "timed_out"]

    /// Extract the summary from a `Stop` payload.
    ///
    /// Returns `.unknown` unless **both** arrays are present and every entry parses. That is also
    /// what an older Claude Code, or a payload we only scanned rather than parsed, produces — the
    /// honest answer, and it deliberately does not resemble either "busy" or "finished".
    public static func read(from payload: [String: Any], now: Date) -> BackgroundEvidence {
        guard let tasks = payload["background_tasks"] as? [[String: Any]] else {
            return .unknown(at: now)
        }
        // A missing or wrong-shaped cron list is a hole in the evidence, not an empty one. Counting
        // it as zero is what let `tasks: [], crons: absent` read as a finished turn.
        let cronList = payload["session_crons"] as? [[String: Any]]
        var malformedCrons = cronList == nil ? 1 : 0
        var crons = 0
        for cron in cronList ?? [] {
            // An entry has to look like a record. We read nothing out of it but its existence.
            if cron.isEmpty { malformedCrons += 1 } else { crons += 1 }
        }

        var running = 0, completed = 0, failed = 0, unrecognised = 0
        var types = Set<String>()
        var records: [SnapshotRecord] = []
        var seenIdentifiers = Set<String>()
        var duplicated = false
        var unnamed = false

        func note(_ id: String?) {
            guard let id else { unnamed = true; return }
            if !seenIdentifiers.insert(id).inserted { duplicated = true }
        }

        for task in tasks {
            let type = (task["type"] as? String).flatMap { $0.isEmpty || $0.count > 32 ? nil : $0 }
            if let type { types.insert(type) }
            let id = (task["id"] as? String).flatMap {
                $0.isEmpty || $0.count > BackgroundRegistry.maximumIdentifierLength ? nil : $0
            }
            note(id)

            let raw = (task["status"] as? String)?.lowercased()
            let state = BackgroundJob.state(fromStatus: raw)
            switch state {
            case .running: running += 1
            case .completed: completed += 1
            case .failed, .stopped: failed += 1
            case .unknown, .absent: unrecognised += 1
            }
            if records.count < BackgroundEvidence.maximumRecords {
                records.append(SnapshotRecord(id: id, type: type, state: state,
                                              kind: BackgroundJob.kind(fromType: type)))
            }
        }
        for cron in cronList ?? [] where !cron.isEmpty {
            let id = (cron["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            note(id)
            if records.count < BackgroundEvidence.maximumRecords {
                records.append(SnapshotRecord(id: id, type: "cron", state: .running,
                                              kind: .recurringWakeup,
                                              recurring: (cron["recurring"] as? Bool) ?? false))
            }
        }

        // The account of *which* jobs is partial whenever an entry could not be named, an id
        // repeated, or the list ran past the cap. A repeated id in particular means the list is
        // not something to reason about as a set.
        let capped = tasks.count + crons > BackgroundEvidence.maximumRecords
        let coverage: BackgroundRegistry.Coverage =
            (unnamed || duplicated || capped) ? .partial : (records.isEmpty ? .unknown : .observed)

        let availability: Availability
        if unrecognised > 0 || malformedCrons > 0 || duplicated {
            // A list that repeats itself is not one we can call complete in either direction.
            availability = .unknown
        } else if running > 0 || crons > 0 {
            availability = .reported
        } else {
            availability = .none
        }

        return BackgroundEvidence(
            availability: availability,
            running: running,
            completed: completed,
            failed: failed,
            unrecognised: unrecognised + malformedCrons,
            crons: crons,
            types: types.sorted(),
            observedAt: now,
            records: records,
            recordCoverage: coverage
        )
    }

    /// One line for a card or a status line. Counts and types only.
    public var summaryLine: String {
        if hasFailure {
            let what = failed == 1 ? "1 background task failed" : "\(failed) background tasks failed"
            return running > 0 ? "\(what) — \(running) still running" : "Turn ended — \(what)"
        }
        switch availability {
        case .reported:
            if running == 0 && crons > 0 {
                return crons == 1
                    ? "Paused — 1 scheduled wakeup pending"
                    : "Paused — \(crons) scheduled wakeups pending"
            }
            let what = types.isEmpty ? "task" : types.joined(separator: ", ")
            var line = running == 1
                ? "Paused — 1 background \(what) still running"
                : "Paused — \(running) background tasks still running (\(what))"
            if crons > 0 { line += " · \(crons) scheduled" }
            return line
        case .none:
            return "Turn complete"
        case .unknown:
            return "Turn ended — completion not confirmed"
        }
    }
}

/// How sure are we that a session's turn actually finished?
///
/// Three answers, not two. The middle one is the whole point: "we could not tell" must be its own
/// state, must be quiet, and must never be rounded up to "done" or down to "needs you".
public enum CompletionCertainty: String, Sendable, Equatable {
    /// Both arrays read cleanly and nothing is left running or scheduled.
    case confirmed
    /// Something is demonstrably still pending. Quiet: the session is waiting on itself.
    case paused
    /// No evidence, unreadable evidence, or evidence too old to be a claim about now. Quiet.
    case uncertain

    /// May a generic "the turn ended" signal become something the user is asked to look at?
    ///
    /// Only when the evidence positively says the turn finished. This is what stops an older
    /// Claude Code, an unreadable payload or an expired reading from manufacturing a completion
    /// alert out of nothing.
    public var supportsCompletionAlert: Bool { self == .confirmed }
}
