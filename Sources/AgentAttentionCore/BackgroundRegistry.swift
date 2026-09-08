import Foundation

/// One piece of work running behind a session, named by the session **and** the task.
///
/// A task id on its own is not an identity. Two sessions can each be running a `T1`, and treating
/// them as one job would let one session's outcome close the other's work. Every lookup here is by
/// the pair.
public struct BackgroundJob: Codable, Sendable, Equatable {
    public struct Identity: Codable, Sendable, Equatable, Hashable {
        /// Which id space this name comes from. A background task and a scheduled cron are
        /// numbered by different systems, so a `1` in one is not a `1` in the other — merging them
        /// would let a cron's outcome close a shell.
        public enum Namespace: String, Codable, Sendable, Equatable, Hashable {
            case task
            case cron
        }

        public var sessionID: String
        public var taskID: String
        public var namespace: Namespace

        public init(sessionID: String, taskID: String, namespace: Namespace = .task) {
            self.sessionID = sessionID
            self.taskID = taskID
            self.namespace = namespace
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = (try? c.decode(String.self, forKey: .sessionID)) ?? ""
            taskID = (try? c.decode(String.self, forKey: .taskID)) ?? ""
            // A record written before namespaces existed came from the task space.
            namespace = ((try? c.decodeIfPresent(Namespace.self, forKey: .namespace)) ?? nil) ?? .task
        }
    }

    /// Finite work versus something that stays up. Kept apart from the state, and `unknown` is a
    /// perfectly good answer — `local_bash` covers both a one-shot shell and a monitor, so that
    /// type alone settles nothing.
    public enum Kind: String, Codable, Sendable, Equatable {
        case finite
        case monitor
        case recurringWakeup
        case unknown
    }

    /// Where it got to. `stopped` and `failed` are different things and stay different: one was
    /// ended on purpose, the other went wrong.
    public enum State: String, Codable, Sendable, Equatable {
        case running
        case completed
        case failed
        case stopped
        /// It was in the live set and is not any more, with no outcome ever reported. Neither
        /// finished nor running: the membership signal carries ids only, so its disappearance says
        /// where it went to exactly this extent.
        case absent
        case unknown

        /// Settled. Nothing later moves a job out of one of these.
        public var isTerminal: Bool {
            self == .completed || self == .failed || self == .stopped
        }
    }

    /// Which evidence this came from. A snapshot is a photograph taken when a turn ended; a stream
    /// frame is the session saying something as it happens. They are not interchangeable.
    public enum Source: String, Codable, Sendable, Equatable {
        case stopSnapshot
        case lifecycleStream
    }

    public var identity: Identity
    public var kind: Kind
    public var state: State
    public var source: Source
    /// The vocabulary the client used, when it gave one. Reported, never interpreted beyond `kind`.
    public var typeLabel: String?
    /// Optional correlation to the tool call that started it. Absent is normal.
    public var toolUseID: String?
    /// Only ever set for a scheduled wakeup that said so.
    public var recurring: Bool?
    public var firstSeenAt: Date
    public var observedAt: Date
    /// Housekeeping the CLI does not present as user work. Kept, and kept out of the counts.
    public var ambient: Bool

    public init(identity: Identity, kind: Kind = .unknown, state: State = .unknown,
                source: Source, typeLabel: String? = nil, toolUseID: String? = nil,
                recurring: Bool? = nil, firstSeenAt: Date, observedAt: Date,
                ambient: Bool = false) {
        self.identity = identity
        self.kind = kind
        self.state = state
        self.source = source
        self.typeLabel = typeLabel
        self.toolUseID = toolUseID
        self.recurring = recurring
        self.firstSeenAt = firstSeenAt
        self.observedAt = observedAt
        self.ambient = ambient
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(Identity.self, forKey: .identity)
        kind = ((try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil) ?? .unknown
        state = ((try? c.decodeIfPresent(State.self, forKey: .state)) ?? nil) ?? .unknown
        source = ((try? c.decodeIfPresent(Source.self, forKey: .source)) ?? nil) ?? .stopSnapshot
        // Persisted strings are re-bounded on the way in: a state file is a file, and a file can be
        // edited. Anything out of bounds is dropped rather than carried into the UI.
        typeLabel = BackgroundRegistry.bounded((try? c.decodeIfPresent(String.self, forKey: .typeLabel)) ?? nil)
        toolUseID = BackgroundRegistry.bounded((try? c.decodeIfPresent(String.self, forKey: .toolUseID)) ?? nil)
        recurring = (try? c.decodeIfPresent(Bool.self, forKey: .recurring)) ?? nil
        firstSeenAt = (try? c.decode(Date.self, forKey: .firstSeenAt)) ?? Date(timeIntervalSince1970: 0)
        observedAt = (try? c.decode(Date.self, forKey: .observedAt)) ?? firstSeenAt
        ambient = ((try? c.decodeIfPresent(Bool.self, forKey: .ambient)) ?? nil) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case identity, kind, state, source, typeLabel, toolUseID, recurring
        case firstSeenAt, observedAt, ambient
    }

    /// How old this particular observation is. Freshness belongs to the job: one record from four
    /// seconds ago and another from four hours ago are not equally believable just because they
    /// arrived in the same registry.
    public func isStale(at now: Date, after ttl: TimeInterval) -> Bool {
        now.timeIntervalSince(observedAt) > ttl
    }

    /// What kind of *lifespan* this has — which is a different question from what kind of thing it
    /// is.
    ///
    /// A `shell` can be `ls` or `tail -f`; a `subagent` can answer in seconds or sit in a loop.
    /// Neither type promises a finite life, so neither is read as one. Only a type that names a
    /// watching behaviour, or a wakeup that says it recurs, settles this. Everything else is
    /// `unknown`, and `unknown` is a perfectly good thing to show a person.
    static func kind(fromType type: String?, recurring: Bool? = nil) -> Kind {
        if let recurring {
            // A wakeup that fires once is a one-shot, not a recurring monitor. Saying otherwise
            // would put a permanent "monitor running" beside a session that has one alarm set.
            return recurring ? .recurringWakeup : .finite
        }
        switch (type ?? "").lowercased() {
        case "monitor", "watch", "watcher": return .monitor
        // Deliberately absent: `shell`, `bash`, `local_bash`, `subagent`, `local_agent`, `task`.
        // Each covers both a command that ends and one that does not, and a feature name is not a
        // promise about lifespan.
        default: return .unknown
        }
    }

    static func state(fromStatus status: String?) -> State {
        guard let status = status?.lowercased(), !status.isEmpty else { return .unknown }
        if BackgroundEvidence.runningStatuses.contains(status) { return .running }
        if BackgroundEvidence.completedStatuses.contains(status) { return .completed }
        // `killed` is the task_updated spelling of the same thing task_notification calls
        // `stopped`: ended on purpose, which is not the same as gone wrong.
        if ["stopped", "killed", "cancelled", "canceled"].contains(status) { return .stopped }
        if status == "paused" { return .unknown }        // still there, and not running
        if BackgroundEvidence.failedStatuses.contains(status) { return .failed }
        return .unknown
    }
}

/// One validated lifecycle frame from a session this host owns.
///
/// Parsed against the **documented** shapes, which are not flat: the task bookends arrive as
/// `{"type":"system","subtype":"task_started"|"task_progress"|"task_notification"|"task_updated"}`,
/// and only `tool_progress` carries its name at the top level. An earlier cut of this read a
/// flattened `type`, which no client sends — it would have passed its own tests for ever while
/// every real frame fell through to a note.
///
/// Content is deliberately not read. `description`, `prompt` and `summary` are session content;
/// what is kept is the identifier, the type word, the status and the correlation.
public struct BackgroundLifecycleFrame: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case started = "task_started"
        case progress = "task_progress"
        case notification = "task_notification"
        case updated = "task_updated"
        case toolProgress = "tool_progress"
    }

    public var kind: Kind
    public var sessionID: String
    public var taskID: String
    /// The client's own event id, used to notice a replay.
    public var eventID: String?
    public var status: String?
    public var taskType: String?
    public var toolUseID: String?
    /// Housekeeping the CLI does not surface as user work. Recorded, and kept out of the counts a
    /// person is shown — the SDK is explicit that hosts should exclude these from activity.
    public var ambient: Bool

    public init?(_ object: [String: Any]) {
        let top = object["type"] as? String
        let subtype = object["subtype"] as? String
        let kind: Kind
        switch (top, subtype) {
        case ("system", let sub?):
            guard let parsed = Kind(rawValue: sub), parsed != .toolProgress else { return nil }
            kind = parsed
        case ("tool_progress", _):
            kind = .toolProgress
        default:
            return nil
        }

        guard let session = BackgroundRegistry.bounded(object["session_id"]) else { return nil }
        // A frame with no task id names no job. `tool_progress` carries one only sometimes, and
        // without it there is nothing to track — a job that can never be resolved would sit in the
        // registry for ever looking like work.
        guard let taskID = BackgroundRegistry.bounded(object["task_id"]) else { return nil }

        self.kind = kind
        self.sessionID = session
        self.taskID = taskID
        self.eventID = BackgroundRegistry.bounded(object["uuid"])
        self.toolUseID = BackgroundRegistry.bounded(object["tool_use_id"])
        self.ambient = (object["ambient"] as? Bool) ?? (object["skip_transcript"] as? Bool) ?? false

        switch kind {
        case .notification:
            self.status = BackgroundRegistry.bounded(object["status"])
            self.taskType = nil
        case .updated:
            // The patch is the wire-safe subset of what changed; only its status is read.
            let patch = object["patch"] as? [String: Any]
            self.status = BackgroundRegistry.bounded(patch?["status"])
            self.taskType = nil
        case .started:
            self.status = nil
            self.taskType = BackgroundRegistry.bounded(object["task_type"])
                ?? BackgroundRegistry.bounded(object["subagent_type"]).map { _ in "local_agent" }
        case .progress, .toolProgress:
            self.status = nil
            self.taskType = BackgroundRegistry.bounded(object["subagent_type"]).map { _ in "local_agent" }
        }
    }
}

/// Every background job one session is known to have, and an honest account of how well it is
/// known.
///
/// Three things are kept apart on purpose, and this is the third: what the session's main turn is
/// doing, what it is *asking* for, and what is running behind it are separate questions. Merging
/// them is how a running monitor comes to look like an unanswered question, or how a genuine
/// blocker gets cleared by a shell finishing.
public struct BackgroundRegistry: Codable, Sendable, Equatable {
    public static let maximumJobs = 64
    /// Event ids remembered for deduplication. Bounded like everything else.
    public static let maximumRememberedEvents = 512
    public static let maximumIdentifierLength = 128

    /// How much of the picture this is.
    ///
    /// **There is no `complete`.** A stream can drop frames, a reconnect can miss them, an older
    /// client emits none at all, and a snapshot is a photograph of one moment. Nothing here ever
    /// earns the right to say "and that is everything".
    public enum Coverage: String, Codable, Sendable, Equatable {
        /// Nothing has ever been heard. Not "there are no jobs".
        case unknown
        /// Some evidence, known to be incomplete: records were dropped, unnamed, or capped.
        case partial
        /// Evidence arrived and nothing about it is known to be missing — which is still not proof
        /// that nothing else exists.
        case observed
        /// Kept so an exhaustive switch stays honest if a future source can prove completeness.
        /// Nothing produces it today.
        case complete
    }

    /// Every untrusted string that reaches this type goes through here: bounded, non-empty, and
    /// free of control characters. Applied to session ids, task ids, event ids, tool-use ids and
    /// type words alike — an id read off the wire or off disk is no more trustworthy than a prompt.
    static func bounded(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty,
              text.count <= maximumIdentifierLength else { return nil }
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        return text
    }

    public private(set) var jobs: [BackgroundJob]
    /// Jobs dropped to stay within the bound. Any at all means the list is not the whole list.
    public private(set) var evicted: Int
    public private(set) var coverage: Coverage
    /// Event ids already applied, oldest first.
    private var seenEvents: [String]

    public init() {
        jobs = []
        evicted = 0
        coverage = .unknown
        seenEvents = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = ((try? container.decodeIfPresent([BackgroundJob].self, forKey: .jobs)) ?? nil) ?? []
        // A state file is a file, and a file can be edited or corrupted. What comes off disk is
        // validated exactly like what comes off the wire: bounded ids, no duplicate identities, no
        // more than the cap — trusting a persisted array would be trusting an untrusted array with
        // extra steps.
        var seen = Set<BackgroundJob.Identity>()
        var accepted: [BackgroundJob] = []
        var rejected = 0
        for job in stored {
            guard BackgroundRegistry.bounded(job.identity.sessionID) != nil,
                  BackgroundRegistry.bounded(job.identity.taskID) != nil,
                  seen.insert(job.identity).inserted else {
                rejected += 1
                continue
            }
            accepted.append(job)
        }
        if accepted.count > BackgroundRegistry.maximumJobs {
            rejected += accepted.count - BackgroundRegistry.maximumJobs
            accepted.removeFirst(accepted.count - BackgroundRegistry.maximumJobs)
        }
        jobs = accepted
        evicted = (((try? container.decodeIfPresent(Int.self, forKey: .evicted)) ?? nil) ?? 0)
            + rejected
        coverage = ((try? container.decodeIfPresent(Coverage.self, forKey: .coverage)) ?? nil)
            ?? (jobs.isEmpty ? .unknown : .partial)
        let events = ((try? container.decodeIfPresent([String].self, forKey: .seenEvents)) ?? nil) ?? []
        seenEvents = Array(events.compactMap(BackgroundRegistry.bounded)
            .suffix(BackgroundRegistry.maximumRememberedEvents))
        if rejected > 0 { coverage = .partial }
    }

    /// What happened to a frame. Reported rather than swallowed, so a caller can log the truth.
    public enum Outcome: String, Sendable, Equatable {
        case recorded
        /// This exact event has already been applied.
        case duplicate
        /// It names a session this registry does not belong to.
        case wrongSession
        /// It would move a settled job backwards, or arrive before what we already have.
        case outOfOrder
    }

    // MARK: - The lifecycle stream

    /// Fold one validated frame in.
    ///
    /// `ownedBy` is checked here rather than trusted from the frame: a frame naming a different
    /// session is refused outright, and creates nothing. That is the same rule the bridge applies to
    /// results, for the same reason — an id we cannot vouch for must not change what we believe.
    @discardableResult
    public mutating func apply(_ frame: BackgroundLifecycleFrame, ownedBy sessionID: String,
                               at moment: Date) -> Outcome {
        guard frame.sessionID == sessionID else { return .wrongSession }
        if let eventID = frame.eventID {
            guard !seenEvents.contains(eventID) else { return .duplicate }
            seenEvents.append(eventID)
            if seenEvents.count > BackgroundRegistry.maximumRememberedEvents {
                seenEvents.removeFirst(seenEvents.count - BackgroundRegistry.maximumRememberedEvents)
            }
        } else {
            // Undeduplicable traffic is still useful, and is still a hole in the account.
            coverage = .partial
        }

        let identity = BackgroundJob.Identity(sessionID: sessionID, taskID: frame.taskID,
                                              namespace: .task)
        let reported = BackgroundJob.state(fromStatus: frame.status)
        let index = jobs.firstIndex { $0.identity == identity }

        if let index {
            // Settled is settled. A progress frame that overtakes an outcome — or an outcome that
            // arrives twice in different words — must not reopen the job.
            guard !jobs[index].state.isTerminal else { return .outOfOrder }
            if moment < jobs[index].observedAt, reported == .unknown { return .outOfOrder }
            jobs[index].observedAt = moment
            if reported != .unknown {
                jobs[index].state = reported
            } else if frame.status?.isEmpty == false {
                // It told us a status and we could not read it. Leaving the job as "running" would
                // claim knowledge the client has just taken away; unknown is what we actually have.
                jobs[index].state = .unknown
                coverage = .partial
            } else if frame.kind == .progress || frame.kind == .toolProgress {
                jobs[index].state = .running          // progress is evidence of running, nothing more
            }
            if let type = frame.taskType, jobs[index].typeLabel == nil {
                jobs[index].typeLabel = type
                jobs[index].kind = BackgroundJob.kind(fromType: type)
            }
            if let tool = frame.toolUseID, jobs[index].toolUseID == nil {
                jobs[index].toolUseID = tool
            }
            // Where the newest evidence came from. A job first seen in a snapshot and then heard
            // from live is now a stream job, and saying so is how a reader knows how current it is.
            jobs[index].source = .lifecycleStream
            if frame.ambient { jobs[index].ambient = true }
            if coverage == .unknown { coverage = .observed }
            return .recorded
        }

        // A frame about a job we never saw start is still a job. What it is not is proof that we
        // saw the beginning of it.
        var state = reported
        if state == .unknown, frame.status?.isEmpty != false,
           frame.kind == .started || frame.kind == .progress || frame.kind == .toolProgress {
            state = .running
        }
        if state == .unknown { coverage = .partial }
        var job = BackgroundJob(identity: identity,
                                kind: BackgroundJob.kind(fromType: frame.taskType),
                                state: state, source: .lifecycleStream,
                                typeLabel: frame.taskType, toolUseID: frame.toolUseID,
                                firstSeenAt: moment, observedAt: moment, ambient: frame.ambient)
        if frame.kind != .started { coverage = .partial }     // we joined in the middle
        job.observedAt = moment
        insert(job)
        if coverage == .unknown { coverage = .observed }
        return .recorded
    }

    // MARK: - The live membership set

    /// Apply `background_tasks_changed`: **replace** semantics, ids only.
    ///
    /// The SDK is explicit that this is a level signal rather than an edge, and that a consumer
    /// should swap its set for each payload so a missed bookend cannot wedge a stale "running"
    /// indicator. So a job that is no longer in the set stops being reported as running — but it is
    /// marked **absent**, not completed: the payload carries ids, and an id going away says only
    /// that it is no longer live. It is also per-process, so a restart resets to empty and the next
    /// change repopulates it, and it must not be correlated with the edge stream.
    public mutating func applyMembership(taskIDs: [String], ambient: Set<String> = [],
                                         ownedBy sessionID: String, at moment: Date) {
        let live = Set(taskIDs.compactMap { BackgroundRegistry.bounded($0) })
        for index in jobs.indices where jobs[index].identity.sessionID == sessionID
            && jobs[index].identity.namespace == .task {
            let id = jobs[index].identity.taskID
            if live.contains(id) {
                // A settled job is not touched, not even its clock. The level signal and the edge
                // stream are explicitly not correlated, so a finished job can still appear in a
                // membership payload for a moment — and refreshing its timestamp would report a
                // completed job as freshly observed. The disagreement goes on the record instead.
                guard !jobs[index].state.isTerminal else {
                    coverage = .partial
                    continue
                }
                if jobs[index].state == .absent || jobs[index].state == .unknown {
                    jobs[index].state = .running
                }
                jobs[index].observedAt = moment
                if ambient.contains(id) { jobs[index].ambient = true }
            } else if !jobs[index].state.isTerminal {
                // Gone from the live set with no outcome ever reported. Not finished, not running.
                jobs[index].state = .absent
                jobs[index].observedAt = moment
            }
        }
        for id in live where !jobs.contains(where: {
            $0.identity == BackgroundJob.Identity(sessionID: sessionID, taskID: id)
        }) {
            insert(BackgroundJob(identity: BackgroundJob.Identity(sessionID: sessionID, taskID: id),
                                 state: .running, source: .lifecycleStream,
                                 firstSeenAt: moment, observedAt: moment,
                                 ambient: ambient.contains(id)))
        }
        if coverage == .unknown { coverage = .observed }
    }

    /// Evidence arrived that we could not read. The list is no longer something to reason about
    /// as a whole, and says so — without throwing away what is already known.
    public mutating func markPartialCoverage() { coverage = .partial }

    /// The client's process restarted: the level signal is per-process and emits nothing at
    /// startup, so whatever we thought was live is no longer evidence.
    public mutating func processRestarted(at moment: Date) {
        for index in jobs.indices where !jobs[index].state.isTerminal {
            jobs[index].state = .absent
            jobs[index].observedAt = moment
        }
        coverage = .partial
    }

    // MARK: - The Stop snapshot

    /// Fold a `Stop` reading in. Snapshot records never overwrite a stream outcome that is already
    /// settled — a photograph taken when the turn ended cannot un-finish a job.
    public mutating func apply(snapshot: BackgroundEvidence, ownedBy sessionID: String) {
        for record in snapshot.records {
            guard let id = record.id else {
                coverage = .partial                  // an entry we cannot name is a hole
                continue
            }
            let identity = BackgroundJob.Identity(sessionID: sessionID, taskID: id,
                                                  namespace: record.kind == .recurringWakeup
                                                      || record.type == "cron" ? .cron : .task)
            if let index = jobs.firstIndex(where: { $0.identity == identity }) {
                // A snapshot is a photograph of a past moment. It never overwrites something we
                // heard about more recently, and it never un-settles an outcome — a contradiction
                // is recorded as one rather than resolved by whichever arrived last.
                if jobs[index].state.isTerminal {
                    if record.state == .running { coverage = .partial }   // snapshot disagrees
                    continue
                }
                guard snapshot.observedAt >= jobs[index].observedAt else {
                    coverage = .partial                                   // older than what we have
                    continue
                }
                jobs[index].state = record.state
                jobs[index].observedAt = snapshot.observedAt
                jobs[index].source = .stopSnapshot
                if jobs[index].typeLabel == nil { jobs[index].typeLabel = record.type }
                if jobs[index].kind == .unknown {
                    jobs[index].kind = BackgroundJob.kind(fromType: record.type,
                                                          recurring: record.recurring)
                }
                continue
            }
            insert(BackgroundJob(identity: identity,
                                 kind: record.kind, state: record.state, source: .stopSnapshot,
                                 typeLabel: record.type, recurring: record.recurring,
                                 firstSeenAt: snapshot.observedAt, observedAt: snapshot.observedAt))
        }
        switch snapshot.recordCoverage {
        case .partial, .unknown: coverage = .partial
        case .observed, .complete: if coverage == .unknown { coverage = .observed }
        }
    }

    private mutating func insert(_ job: BackgroundJob) {
        jobs.append(job)
        if jobs.count > BackgroundRegistry.maximumJobs {
            let excess = jobs.count - BackgroundRegistry.maximumJobs
            jobs.removeFirst(excess)
            evicted += excess
            coverage = .partial                      // it dropped something; it is not the whole list
        }
    }

    // MARK: - Derived

    /// What a person is shown. Ambient housekeeping — the CLI's own watchers — is kept but is not
    /// presented as the session's work, which is what the SDK asks hosts to do.
    public var visible: [BackgroundJob] { jobs.filter { !$0.ambient } }

    public var running: Int { visible.filter { $0.state == .running }.count }
    public var completed: Int { visible.filter { $0.state == .completed }.count }
    public var failed: Int { visible.filter { $0.state == .failed }.count }
    public var stopped: Int { visible.filter { $0.state == .stopped }.count }
    public var unknownState: Int { visible.filter { $0.state == .unknown }.count }
    public var absent: Int { visible.filter { $0.state == .absent }.count }
    public var monitors: Int {
        visible.filter { $0.kind == .monitor || $0.kind == .recurringWakeup }.count
    }

    /// Jobs still going, newest observation first — the ones a person might want to see.
    public var active: [BackgroundJob] {
        visible.filter { $0.state == .running }.sorted { $0.observedAt > $1.observedAt }
    }

    /// Can this registry establish that **nothing** is running behind the session?
    ///
    /// No. Not today, and the property exists to say so at the call site rather than let an empty
    /// array read as an answer. A stream can miss frames, an older client sends none, and a
    /// snapshot describes one moment — so "we have not heard of a job" is never "there is no job".
    public var provesNothingIsRunning: Bool { coverage == .complete && running == 0 }

    /// A short line for a card: what is running, in the user's words.
    public func summary(at now: Date, staleAfter ttl: TimeInterval) -> String? {
        let live = active.filter { !$0.isStale(at: now, after: ttl) }
        guard !live.isEmpty else { return nil }
        let monitors = live.filter { $0.kind == .monitor || $0.kind == .recurringWakeup }.count
        if monitors == live.count {
            return monitors == 1 ? "1 monitor running" : "\(monitors) monitors running"
        }
        let jobs = live.count == 1 ? "1 background job" : "\(live.count) background jobs"
        return monitors > 0 ? "\(jobs), \(monitors) a monitor" : jobs
    }

    private enum CodingKeys: String, CodingKey {
        case jobs, evicted, coverage, seenEvents
    }
}
