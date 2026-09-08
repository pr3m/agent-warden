import Foundation

/// A compact, read-only view of the attention queue, meant to be consumed by something other than
/// a human looking at a screen — a script, or an assistant that would otherwise need a screenshot.
///
/// Three properties matter more than the contents:
///
/// 1. **It never mutates anything.** It reads saved state; it does not drain the spool, sweep, or
///    write. Querying can therefore never lose an alert or change what the app does next.
/// 2. **It distinguishes "nothing is waiting" from "nothing is watching".** A queue that reads
///    empty because the app is not running is a different answer, and `app.running`,
///    `app.stateAgeSeconds` and `app.fresh` say which one you are looking at.
/// 3. **It never turns "we could not check" into "it is gone".** Under a sandbox that refuses
///    process inspection, `app.running` is `null` and process states read `unknown`. Reporting a
///    live app as dead is worse than admitting the limit.
public struct StatusReport: Codable, Sendable, Equatable {
    public static let currentSchema = 3

    public struct AppPresence: Codable, Sendable, Equatable {
        /// `true` alive, `false` confirmed gone, **`null` we were not allowed to look**.
        public var running: Bool?
        /// Did process inspection work at all in this context?
        public var livenessVerified: Bool
        /// "running", "notRunning" or "unknown" — the same information, spelled out.
        public var presence: String
        public var pid: Int32?
        public var version: String?
        public var startedAt: Date?
        /// When the queue below was last written.
        public var stateWrittenAt: Date?
        public var stateAgeSeconds: Double?
        /// Did the saved queue parse? A recent mtime on an unreadable file is not freshness.
        public var stateReadable: Bool
        /// True only when the app is confirmed running, its state parsed, and it was written
        /// recently. Anything else means the queue below may be wrong.
        public var fresh: Bool
        /// Hook events written but not yet folded into the queue. Non-zero with `running: false`
        /// means alerts are waiting for the app to start.
        public var unprocessedEvents: Int
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var kind: String
        /// "reported" — an official Claude Code hook said so. Every item has one; the app does not
        /// invent attention from elapsed silence.
        public var source: String
        public var project: String
        /// The full, stable Claude Code session id. Short ids collide; machines get the real one.
        public var sessionID: String
        /// Abbreviated id, for display only. Never use it to identify a session.
        public var displayID: String
        public var cwd: String
        public var reason: String
        public var waitingSeconds: Int
        public var occurrences: Int
        public var snoozedUntil: Date?
        /// "exactTab", "appOnly" or "none" — what clicking this can actually achieve.
        public var clickTarget: String
        /// The label the button carries, e.g. "Open Ghostty".
        public var openLabel: String
        public var terminal: String
        /// "alive", "dead", "unknown" (inspection refused) or "unidentified" (no pid recorded).
        public var process: String
    }

    /// What one registry scan established, kept apart from anything hooks reported.
    public struct DiscoverySummary: Codable, Sendable, Equatable {
        /// When a scan last placed a session in the list. Nil if none ever has.
        public var lastScanAt: Date?
        public var ageSeconds: Double?
        /// Sessions we know about only because the registry mentioned them.
        public var sessionsAwaitingFirstHook: Int
        /// Sessions a real hook has reported for.
        public var sessionsWithHookCoverage: Int
        /// Present only when the running app supplied its latest scan.
        public var registryPresent: Bool?
        public var processInspectionAvailable: Bool?
        public var verified: Int?
        public var rejected: Int?
        public var malformed: Int?
    }

    /// What the session's last `Stop` said it left running. Counts and task types only — never a
    /// task's description, command or prompt.
    public struct BackgroundSummary: Codable, Sendable, Equatable {
        /// "reported" (arrays read cleanly), "none" (nothing left running) or "unknown"
        /// (fields missing, malformed, or carrying a status we do not recognise).
        public var availability: String
        public var running: Int
        public var failed: Int
        public var crons: Int
        public var types: [String]
        public var observedAt: Date
        public var ageSeconds: Double
        /// True only for a fresh "reported" reading with something still running. A stale reading is
        /// not a claim about now.
        public var waiting: Bool
        /// True only when the arrays were present, everything in them had finished, **and** that
        /// reading is still current.
        ///
        /// It used to be true of any clean reading, however old — so an observation from an hour
        /// ago, or one the session had already worked past, read as certainty about now. A
        /// completion is a claim about the present or it is not a completion.
        public var confirmedComplete: Bool
        /// The reading is real and is still shown, but it describes a moment that has passed:
        /// either it aged out, or the session went back to work after it was taken.
        public var observationOnly: Bool
        public var summary: String
        /// Every background job known for this session, each with its own identity, state and age.
        public var jobs: [JobSummary]
        /// How complete that list is: `unknown`, `partial` or `observed`. Never "all of them".
        public var coverage: String
        /// Jobs dropped to stay inside the bound, if any.
        public var evicted: Int
    }

    /// One background job, as a consumer sees it.
    public struct JobSummary: Codable, Sendable, Equatable {
        /// Both halves of the identity. A task id alone belongs to no one.
        public var sessionID: String
        public var taskID: String
        /// `finite`, `monitor`, `recurringWakeup` or `unknown`.
        public var kind: String
        /// `running`, `completed`, `failed`, `stopped` or `unknown`.
        public var state: String
        /// `stopSnapshot` or `lifecycleStream`.
        public var source: String
        /// The client's own word for it, when it gave one.
        public var type: String?
        public var toolUseID: String?
        public var recurring: Bool?
        public var observedAt: Date
        public var ageSeconds: Double
        /// This job's own freshness, not the registry's.
        public var stale: Bool
    }

    /// Built here rather than inline so the freshness rule has one home — and can be tested
    /// directly, which is how the stale-completion bug was found.
    public static func backgroundSummary(_ state: SessionState, config: AttentionConfig,
                                         now: Date) -> BackgroundSummary? {
        guard let evidence = state.background else { return nil }
        let age = now.timeIntervalSince(evidence.observedAt)
        let stale = evidence.isStale(at: now, after: config.backgroundEvidenceTTLSeconds)
        // Superseded means the session did real work after this reading was taken. The reading is
        // still the best description of what it left running; it is no longer a claim about now.
        let superseded = state.backgroundSupersededAt != nil
        let jobs = state.jobs.jobs.map { job -> JobSummary in
            let jobAge = now.timeIntervalSince(job.observedAt)
            return JobSummary(
                sessionID: job.identity.sessionID,
                taskID: job.identity.taskID,
                kind: job.kind.rawValue,
                state: job.state.rawValue,
                source: job.source.rawValue,
                type: job.typeLabel,
                toolUseID: job.toolUseID,
                recurring: job.recurring,
                observedAt: job.observedAt,
                ageSeconds: (jobAge * 10).rounded() / 10,
                stale: job.isStale(at: now, after: config.backgroundEvidenceTTLSeconds))
        }
        return BackgroundSummary(
            availability: evidence.availability.rawValue,
            running: evidence.running,
            failed: evidence.failed,
            crons: evidence.crons,
            types: evidence.types,
            observedAt: evidence.observedAt,
            ageSeconds: (age * 10).rounded() / 10,
            waiting: evidence.isWaitingOnBackgroundWork && !stale,
            confirmedComplete: evidence.isConfirmedComplete && !stale && !superseded,
            observationOnly: stale || superseded,
            summary: stale && evidence.isWaitingOnBackgroundWork
                ? "Last seen running background work, but that reading is now stale"
                : evidence.summaryLine,
            jobs: jobs,
            coverage: state.jobs.coverage.rawValue,
            evicted: state.jobs.evicted
        )
    }

    public struct SessionSummary: Codable, Sendable, Equatable {
        public var sessionID: String
        public var displayID: String
        public var project: String
        public var cwd: String
        public var state: String
        public var terminal: String
        public var tty: String?
        public var lastEventAgeSeconds: Int
        public var waiting: Bool
        public var process: String
        public var clickTarget: String
        public var openLabel: String
        /// The session's own name, when Claude Code has one for it.
        public var title: String?
        /// Where that name came from, verbatim from the registry: `user`/`custom`/… means a person
        /// chose it; `derived`/`auto` means the client generated it. A consumer that shows names
        /// should treat the second kind as an identifier, not a label.
        public var titleSource: String?
        /// What this session is called on screen — the same rule the app's own rows use, so a voice
        /// client and the panel cannot disagree about which session is which.
        public var displayName: String
        /// The branch this session is on **now**, read from its working directory. Nil when nothing
        /// has been read for the directory it is currently in.
        public var branch: String?
        /// `read`, `pending`, or the reading's own failure state (`denied`, `timedOut`, …).
        public var branchAvailability: String
        /// How that branch was established. Only ever `git` — the launch stamp is reported apart.
        public var branchSource: String?
        /// When the reading was taken, and which directory it is about.
        public var branchReadAt: Date?
        public var branchPath: String?
        /// **Deprecated.** The branch stamped into the transcript when the session started. It was
        /// observed reading `main` for five sessions each on their own `cs/…` branch, so it is not
        /// an answer to "which branch is this on". Kept for existing consumers; use `branch`.
        public var gitBranch: String?
        /// Has a real hook ever reported for this session? Deliberately separate from `attention`:
        /// having heard from a session once says nothing about whether it needs you now.
        public var hookCoverage: Bool
        /// What we can say about this session needing you, right now:
        ///
        /// - `waiting` — it asked for something and the ask is open.
        /// - `none` — we positively know it is not asking: working, paused on its own background
        ///   work, or its wait was dealt with.
        /// - `uncertain` — its turn ended and nothing confirmed how. Not "quiet".
        /// - `awaitingFirstHook` — found running, never reported. Also not "quiet".
        public var attention: String
        /// Verbatim from the registry, never interpreted. Goes stale by design.
        public var registryStatus: String?
        /// Present once a `Stop` has been seen for this session.
        public var background: BackgroundSummary?
        /// A terminal tab the user confirmed for this session, and how much it is worth now.
        ///
        /// `clickTarget` above already says what a click can achieve; this says *why*. It is
        /// reported so nothing has to infer exact navigation from the fact that an app came
        /// forward — `provenance` is `userConfirmed` because a person said so, and `verdict` is
        /// checked against this Ghostty and this Claude process at the moment of asking.
        public var link: LinkSummary?
    }

    public struct LinkSummary: Codable, Sendable, Equatable {
        public var terminalID: String
        public var terminalName: String?
        public var provenance: String
        public var pairedAt: Date
        /// `valid` / `sessionChanged` / `terminalAppChanged` / `terminalAppNotRunning` /
        /// `terminalMissing` / `inspectionDenied`.
        public var verdict: String
        public var usable: Bool
        public var explanation: String
    }

    public struct Counts: Codable, Sendable, Equatable {
        public var pending: Int
        public var snoozed: Int
        public var sessionsTracked: Int
        /// Confirmed by a hook. A discovered-only session is never counted here.
        public var sessionsWorking: Int
        public var sessionsAwaitingFirstHook: Int
        /// Paused on work they started themselves. These are *not* in `pending`: nobody is being
        /// asked for anything, so counting them as attention would be a false alarm.
        public var sessionsWaitingOnBackground: Int
        /// Sessions whose turn ended without anything confirming how. Not waiting, not quiet —
        /// unknown. While any of these exist, `pending: 0` is not the whole answer.
        public var sessionsUncertain: Int
    }

    public var schema: Int
    public var generatedAt: Date
    public var app: AppPresence
    public var counts: Counts
    public var discovery: DiscoverySummary
    public var pending: [Entry]
    public var snoozed: [Entry]
    public var sessions: [SessionSummary]
    /// Plain sentences about anything that would make the numbers above misleading.
    public var warnings: [String]

    /// Can a caller act on `counts.pending == 0` as "nothing needs me"?
    public var answerIsTrustworthy: Bool { app.fresh && warnings.isEmpty }
}

extension StatusReport {
    /// Build the report from what is on disk. Read-only.
    public static func build(
        store: EventStore,
        config: AttentionConfig,
        liveness: LivenessProbing = SystemLiveness(),
        discovery latestScan: DiscoveryReport? = nil,
        now: Date = Date(),
        pairings: [String: TerminalPairing] = [:],
        ghostty: ProcessFingerprint? = nil,
        terminalExists: ((String) -> Bool?)? = nil
    ) -> StatusReport {
        let stateWrittenAt = store.stateModifiedAt()
        let snapshot = store.loadSnapshot()
        // A file that exists but will not parse is not a fresh queue; it is a broken one.
        let stateReadable = stateWrittenAt == nil || snapshot != nil
        let appStatus = store.readAppStatus()
        let unprocessed = store.pendingSpoolCount()
        let stateAge = stateWrittenAt.map { now.timeIntervalSince($0) }

        let appVerdict: LivenessVerdict = appStatus
            .map { liveness.probe(pid: $0.pid, startedAt: $0.pidStartedAt) } ?? .dead
        let running: Bool? = {
            switch appVerdict {
            case .alive: return true
            case .dead: return appStatus == nil ? false : false
            case .unknown: return nil
            }
        }()
        let livenessVerified = appVerdict != .unknown

        // Three sweeps of slack, and never less than half a minute, so a machine under load does
        // not report itself stale.
        let freshWindow = max(config.sweepIntervalSeconds * 3, 30)
        let recentEnough = stateAge.map { $0 <= freshWindow } ?? false
        let fresh = (running == true) && stateReadable && recentEnough

        var warnings: [String] = []
        switch appVerdict {
        case .unknown:
            warnings.append("Process inspection is unavailable here, so whether Agent Warden is running could not be checked. Run this on the host session for an accurate answer.")
        case .dead where appStatus == nil:
            warnings.append("Agent Warden is not running: this is the last saved queue, not a live one.")
        case .dead:
            warnings.append("Agent Warden's recorded process is gone: this is the last saved queue, not a live one.")
        case .alive:
            if !recentEnough, let age = stateAge {
                warnings.append(String(format: "The queue was last written %.0fs ago, longer than expected — treat it as stale.", age))
            }
        }
        if stateWrittenAt == nil {
            warnings.append("No saved queue exists yet: the app has not completed a cycle on this machine.")
        } else if !stateReadable {
            warnings.append("The saved queue exists but could not be read; the counts below are empty because of that, not because nothing is waiting.")
        }
        if unprocessed > 0 && running != true {
            warnings.append("\(unprocessed) hook event(s) are waiting to be processed; start the app to see them.")
        }

        func processState(_ identity: SessionIdentity) -> String {
            guard let pid = identity.claudePID else { return "unidentified" }
            return liveness.probe(pid: pid, startedAt: identity.claudePIDStartedAt).rawValue
        }

        func entry(_ item: AttentionItem) -> Entry {
            let plan = TerminalTarget.plan(for: item.identity)
            return Entry(
                kind: item.kind.rawValue,
                source: item.source == .explicit ? "reported" : "suspected",
                project: item.identity.projectName,
                sessionID: item.identity.sessionID,
                displayID: item.identity.shortSessionID,
                cwd: item.identity.cwd,
                reason: item.detail,
                waitingSeconds: max(0, Int(now.timeIntervalSince(item.firstSeenAt))),
                occurrences: item.occurrences,
                snoozedUntil: item.snoozedUntil,
                clickTarget: plan.confidence.rawValue,
                openLabel: plan.actionLabel,
                terminal: item.identity.terminalName,
                process: processState(item.identity)
            )
        }

        let items = snapshot?.items ?? []
        let ordered = items.sorted { lhs, rhs in
            if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank > rhs.kind.rank }
            return lhs.firstSeenAt < rhs.firstSeenAt
        }
        let pending = ordered.filter { $0.isVisible(at: now) }.map(entry)
        let snoozed = ordered.filter { !$0.isVisible(at: now) }.map(entry)

        if pending.contains(where: { $0.process == LivenessVerdict.dead.rawValue }) {
            warnings.append("At least one waiting session's process is gone; the app will clear it on its next sweep.")
        }

        let sessionStates = snapshot?.sessions.values.sorted { $0.identity.sessionID < $1.identity.sessionID } ?? []

        // Freshness of discovery is separate from freshness of the queue: one says when we last
        // looked for sessions, the other when we last heard from one.
        let lastScan = latestScan?.scannedAt ?? sessionStates.compactMap { $0.discovery?.discoveredAt }.max()
        let discoverySummary = DiscoverySummary(
            lastScanAt: lastScan,
            ageSeconds: lastScan.map { ((now.timeIntervalSince($0)) * 10).rounded() / 10 },
            sessionsAwaitingFirstHook: sessionStates.filter { !$0.hasHookEvidence }.count,
            sessionsWithHookCoverage: sessionStates.filter { $0.hasHookEvidence }.count,
            registryPresent: latestScan?.registryPresent,
            processInspectionAvailable: latestScan?.inspectionAvailable,
            verified: latestScan.map { $0.verified.count },
            rejected: latestScan.map { $0.rejected.count },
            malformed: latestScan?.malformed
        )
        if discoverySummary.sessionsAwaitingFirstHook > 0 {
            warnings.append("\(discoverySummary.sessionsAwaitingFirstHook) session(s) were found in Claude Code's registry but have not yet reported through a hook; their attention state is unknown, not quiet.")
        }
        let uncertainCount = sessionStates.filter { attentionCertainty($0) == "uncertain" }.count
        if uncertainCount > 0 {
            warnings.append("\(uncertainCount) session(s) ended a turn without anything confirming how it ended; whether they need you is unknown, not quiet.")
        }
        func backgroundSummary(_ state: SessionState) -> BackgroundSummary? {
            StatusReport.backgroundSummary(state, config: config, now: now)
        }

        /// What can be said about this session needing you *now* — which is a different question
        /// from whether a hook has ever reported for it.
        func attentionCertainty(_ state: SessionState) -> String {
            // The rule itself lives on `SessionState`, so the panel and this report cannot drift
            // into saying different things about the same session.
            state.attentionCertainty(at: now, ttl: config.backgroundEvidenceTTLSeconds).rawValue
        }

        func linkSummary(_ state: SessionState) -> LinkSummary? {
            guard let pairing = pairings[state.identity.sessionID] else { return nil }
            let verdict = PairingValidator.validate(
                pairing: pairing,
                sessionPID: state.identity.claudePID,
                sessionPIDStartedAt: state.identity.claudePIDStartedAt,
                ghostty: ghostty,
                terminalExists: terminalExists?(pairing.terminalID)
            )
            return LinkSummary(
                terminalID: pairing.terminalID,
                terminalName: pairing.terminalName,
                provenance: pairing.provenance,
                pairedAt: pairing.pairedAt,
                verdict: verdict.rawValue,
                usable: verdict.isUsable,
                explanation: verdict.explanation
            )
        }

        let sessions = sessionStates.map { state in
            let plan = TerminalTarget.plan(for: state.identity)
            return SessionSummary(
                sessionID: state.identity.sessionID,
                displayID: state.identity.shortSessionID,
                project: state.identity.projectName,
                cwd: state.identity.cwd,
                state: state.activity.rawValue,
                terminal: state.identity.terminalName,
                tty: state.identity.tty,
                lastEventAgeSeconds: max(0, Int(now.timeIntervalSince(state.lastEventAt))),
                waiting: state.currentItemID != nil,
                process: processState(state.identity),
                clickTarget: plan.confidence.rawValue,
                openLabel: plan.actionLabel,
                title: state.identity.title,
                titleSource: state.identity.titleSource,
                displayName: state.identity.displayName,
                branch: state.identity.branchFact?.branch,
                branchAvailability: state.identity.branchAvailability,
                branchSource: state.identity.branchFact?.source,
                branchReadAt: state.identity.branchFact?.readAt,
                branchPath: state.identity.branchFact?.path,
                gitBranch: state.identity.gitBranch,
                hookCoverage: state.hasHookEvidence,
                attention: attentionCertainty(state),
                registryStatus: state.discovery?.registryStatus,
                background: backgroundSummary(state),
                link: linkSummary(state)
            )
        }

        return StatusReport(
            schema: currentSchema,
            generatedAt: now,
            app: AppPresence(
                running: running,
                livenessVerified: livenessVerified,
                presence: running == true ? "running" : (running == false ? "notRunning" : "unknown"),
                pid: running == true ? appStatus?.pid : nil,
                version: appStatus?.version,
                startedAt: appStatus?.startedAt,
                stateWrittenAt: stateWrittenAt,
                stateAgeSeconds: stateAge.map { ($0 * 10).rounded() / 10 },
                stateReadable: stateReadable,
                fresh: fresh,
                unprocessedEvents: unprocessed
            ),
            counts: Counts(
                pending: pending.count,
                snoozed: snoozed.count,
                sessionsTracked: sessions.count,
                sessionsWorking: sessions.filter { $0.state == SessionActivityState.working.rawValue }.count,
                sessionsAwaitingFirstHook: sessions.filter { !$0.hookCoverage }.count,
                sessionsWaitingOnBackground: sessions.filter { $0.background?.waiting == true }.count,
                sessionsUncertain: sessions.filter { $0.attention == "uncertain" }.count
            ),
            discovery: discoverySummary,
            pending: pending,
            snoozed: snoozed,
            sessions: sessions,
            warnings: warnings
        )
    }

    public func jsonString() -> String {
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"could not encode status\"}"
        }
        return text
    }

    /// Same information, for a human at a terminal.
    public func textSummary() -> String {
        var lines: [String] = []
        let presence: String
        switch app.running {
        case .some(true): presence = app.fresh ? "live" : "running, state stale"
        case .some(false): presence = "NOT RUNNING"
        case .none: presence = "UNKNOWN (process inspection unavailable)"
        }
        var header = "Agent Warden: \(presence)"
        if let age = app.stateAgeSeconds { header += String(format: " · queue written %.0fs ago", age) }
        lines.append(header)
        var tally = "waiting: \(counts.pending)  snoozed: \(counts.snoozed)  sessions: \(counts.sessionsTracked) (\(counts.sessionsWorking) working"
        if counts.sessionsWaitingOnBackground > 0 {
            tally += ", \(counts.sessionsWaitingOnBackground) on background work"
        }
        if counts.sessionsUncertain > 0 { tally += ", \(counts.sessionsUncertain) uncertain" }
        if counts.sessionsAwaitingFirstHook > 0 { tally += ", \(counts.sessionsAwaitingFirstHook) awaiting first hook" }
        lines.append(tally + ")")
        for session in sessions where !session.hookCoverage {
            lines.append("  (discovered) \(session.project) — awaiting first hook, attention unknown")
        }
        for session in sessions where session.background?.waiting == true {
            lines.append("  (background) \(session.project) — \(session.background?.summary ?? "paused")")
        }

        if pending.isEmpty {
            lines.append(answerIsTrustworthy ? "  nothing is waiting for you" : "  nothing waiting in this snapshot — see the warnings below")
        }
        for item in pending {
            let mins = item.waitingSeconds / 60
            let age = mins >= 1 ? "\(mins)m" : "\(item.waitingSeconds)s"
            lines.append("  [\(item.kind)] \(item.project) — \(item.reason) (\(item.source), \(age)"
                         + (item.occurrences > 1 ? ", ×\(item.occurrences)" : "") + ")")
        }
        for item in snoozed {
            lines.append("  (snoozed) \(item.project) — \(item.reason)")
        }
        for warning in warnings {
            lines.append("  ! \(warning)")
        }
        return lines.joined(separator: "\n")
    }
}
