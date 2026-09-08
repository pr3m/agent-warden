import Foundation

/// Heartbeat file written by `aa-emit` on every hook, one per session.
/// Ordinary work does not go through the spool — it would churn a file per tool call — so this
/// is how the app learns a session is still busy.
public struct SessionHeartbeat: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var identity: SessionIdentity
    public var lastEventAt: Date
    public var lastHookEvent: String
    public var lastSignal: SignalClass

    public init(
        schema: Int = SessionHeartbeat.currentSchema,
        identity: SessionIdentity,
        lastEventAt: Date,
        lastHookEvent: String,
        lastSignal: SignalClass
    ) {
        self.schema = schema
        self.identity = identity
        self.lastEventAt = lastEventAt
        self.lastHookEvent = lastHookEvent
        self.lastSignal = lastSignal
    }
}

/// Everything the engine needs to come back after a restart.
public struct EngineSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var items: [AttentionItem]
    public var sessions: [String: SessionState]
    public var recentEventIDs: [String]
    public var savedAt: Date

    public init(
        version: Int = EngineSnapshot.currentVersion,
        items: [AttentionItem],
        sessions: [String: SessionState],
        recentEventIDs: [String],
        savedAt: Date
    ) {
        self.version = version
        self.items = items
        self.sessions = sessions
        self.recentEventIDs = recentEventIDs
        self.savedAt = savedAt
    }
}

/// The single attention queue.
///
/// The organising idea is the **waiting episode**. A session opens an episode the moment it needs
/// a human, and closes it only by doing real work again. Every signal that arrives while the
/// episode is open lands on the same queue item: the count goes up, the description sharpens if
/// the new signal is more specific, and a snooze or a dismissal survives. That is what stops the
/// same wait being announced two or three times as Claude Code emits its own sequence of
/// notifications for it.
///
/// Other rules it enforces:
/// - ordinary work resolves the session's item, which is what keeps the app quiet,
/// - explicit hook signals and inferred stalls are tracked separately and never merged,
/// - a stall is only ever inferred about a process we have positively identified as alive,
/// - events that predate what we already know are ignored, so a replayed file cannot resurrect
///   an alert the user has already dealt with,
/// - dead processes and stale records leave the queue on their own.
///
/// It owns no UI and no I/O: `Date` and process liveness are injected, so every rule above is
/// exercised in tests without sleeping or spawning anything.
///
/// Not thread-safe by design; every caller drives it from the main thread.
public final class AttentionEngine {
    public private(set) var config: AttentionConfig
    private let clock: ClockProviding
    private let liveness: LivenessProbing

    private var storage: [String: AttentionItem] = [:]
    private var sessionStates: [String: SessionState] = [:]
    private var recentEventIDs: [String] = []
    private var recentEventIDSet: Set<String> = []

    private let recentEventIDLimit = 512

    public init(
        config: AttentionConfig = .default,
        clock: ClockProviding = SystemClock(),
        liveness: LivenessProbing = SystemLiveness(),
        restoring snapshot: EngineSnapshot? = nil
    ) {
        self.config = config.validated()
        self.clock = clock
        self.liveness = liveness

        guard let snapshot, snapshot.version == EngineSnapshot.currentVersion else { return }

        sessionStates = snapshot.sessions
        recentEventIDs = Array(snapshot.recentEventIDs.suffix(recentEventIDLimit))
        recentEventIDSet = Set(recentEventIDs)

        // Migration, and it has exactly one rule: **a real ask survives; an unsupported claim does
        // not.** Two kinds of record fail that test.
        //
        // A queue saved by a build that still inferred stalls may carry a `suspectedStall`; elapsed
        // silence is no longer evidence of anything.
        //
        // A queue saved before completion evidence existed may carry a "turn complete" or an idle
        // card that nothing now supports. Re-presenting it would be asserting a milestone we cannot
        // stand behind, so a generic item is kept only when the session's own evidence still
        // confirms the turn finished. Questions, approvals, stage decisions and errors are always
        // kept, with their snoozes and dismissals untouched.
        let now = clock.now
        func survivesMigration(_ item: AttentionItem) -> Bool {
            guard item.kind != .suspectedStall else { return false }
            guard item.kind.isGeneric else { return true }
            let certainty = sessionStates[item.sessionID]?
                .completionCertainty(at: now, ttl: self.config.backgroundEvidenceTTLSeconds) ?? .uncertain
            return certainty.supportsCompletionAlert
        }

        let kept = snapshot.items.filter(survivesMigration)
        for item in kept { storage[item.id] = item }

        // Re-link items to sessions, inventing a session record for any orphan so liveness and
        // staleness still apply to it.
        for item in kept {
            if var session = sessionStates[item.sessionID] {
                session.currentItemID = item.id
                session.episodeID = item.episodeID
                sessionStates[item.sessionID] = session
            } else {
                sessionStates[item.sessionID] = SessionState(
                    identity: item.identity,
                    activity: .awaitingUser,
                    lastEventAt: item.lastSeenAt,
                    lastActivityAt: item.firstSeenAt,
                    episodeID: item.episodeID,
                    currentItemID: item.id
                )
            }
        }

        // A session whose card was just dropped must stop saying it is waiting for you. Clearing
        // the link and leaving the row reading "waiting at the prompt" would keep the same false
        // claim, just without the card. Passive unknown is the honest state.
        let keptSessionIDs = Set(kept.map(\.sessionID))
        for (id, session) in sessionStates {
            guard let itemID = session.currentItemID, storage[itemID] == nil else { continue }
            var repaired = session
            repaired.currentItemID = nil
            if !keptSessionIDs.contains(id), repaired.activity == .awaitingUser {
                repaired.activity = .unknown
            }
            sessionStates[id] = repaired
        }
    }

    // MARK: - Read side

    public var sessions: [String: SessionState] { sessionStates }

    /// Put a session back after a test has folded something into its registry directly. Only the
    /// tests use this; the engine's own paths go through `ingest`.
    func replaceSessionForTesting(_ session: SessionState) {
        sessionStates[session.identity.sessionID] = session
    }

    public func session(_ id: String) -> SessionState? { sessionStates[id] }

    public func item(id: String) -> AttentionItem? { storage[id] }

    /// Everything in the queue, snoozed included.
    public func allItems() -> [AttentionItem] { sorted(Array(storage.values)) }

    /// What the user should be looking at right now.
    public func visibleItems(at now: Date? = nil) -> [AttentionItem] {
        let moment = now ?? clock.now
        return sorted(storage.values.filter { $0.isVisible(at: moment) })
    }

    public func snoozedItems(at now: Date? = nil) -> [AttentionItem] {
        let moment = now ?? clock.now
        return sorted(storage.values.filter { !$0.isVisible(at: moment) })
    }

    /// Sessions paused on work they started, rather than on you.
    public func sessionsWaitingOnBackgroundWork(at now: Date? = nil) -> [SessionState] {
        let moment = now ?? clock.now
        return sessionStates.values
            .filter { $0.isWaitingOnBackgroundWork(at: moment, ttl: config.backgroundEvidenceTTLSeconds) }
            .sorted { $0.identity.sessionID < $1.identity.sessionID }
    }

    /// The number shown in the menu bar.
    public var pendingCount: Int { visibleItems().count }
    public var snoozedCount: Int { snoozedItems().count }

    /// Most blocking first, then the one that has been waiting longest.
    private func sorted(_ items: [AttentionItem]) -> [AttentionItem] {
        items.sorted { lhs, rhs in
            if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank > rhs.kind.rank }
            if lhs.firstSeenAt != rhs.firstSeenAt { return lhs.firstSeenAt < rhs.firstSeenAt }
            return lhs.id < rhs.id
        }
    }

    public func updateConfig(_ newValue: AttentionConfig) { config = newValue.validated() }

    public func snapshot() -> EngineSnapshot {
        EngineSnapshot(
            items: Array(storage.values),
            sessions: sessionStates,
            recentEventIDs: recentEventIDs,
            savedAt: clock.now
        )
    }

    // MARK: - Ingest

    @discardableResult
    public func ingest(_ events: [EmittedEvent]) -> [EngineEffect] {
        events
            .sorted { $0.occurredAt < $1.occurredAt }
            .flatMap { ingest($0) }
    }

    /// What a record *means*, whatever it was labelled when it was written.
    ///
    /// Records already on disk say `activity` for `SubagentStop` — that is what the installed hooks
    /// passed, and what earlier builds classified. Replaying one must not close a request the parent
    /// made moments before, so a known child-lifecycle event is read as housekeeping here, at the
    /// one boundary every record passes through. Nothing else is reinterpreted: a genuine
    /// `PostToolUse` or `UserPromptSubmit` still resumes the turn exactly as it did.
    static let childLifecycleEvents: Set<String> = ["SubagentStop", "SubagentStart"]

    static func effectiveSignal(_ signal: SignalClass, hookEvent: String) -> SignalClass {
        guard signal == .activity, childLifecycleEvents.contains(hookEvent) else { return signal }
        return .housekeeping
    }

    @discardableResult
    public func ingest(_ event: EmittedEvent) -> [EngineEffect] {
        // Forward compatibility: a newer emitter's records are skipped, not guessed at.
        guard event.schema == EmittedEvent.currentSchema else { return [] }
        guard !event.sessionID.isEmpty else { return [] }
        guard !recentEventIDSet.contains(event.id) else { return [] }

        let now = clock.now
        // A spool file left over from days ago must not resurrect an alert.
        if now.timeIntervalSince(event.occurredAt) > config.maxItemAgeSeconds { return [] }

        rememberEventID(event.id)

        switch AttentionEngine.effectiveSignal(event.signal, hookEvent: event.hookEvent) {
        case .sessionStart:
            return applySessionStart(event)
        case .sessionEnd:
            return applySessionEnd(event)
        case .activity:
            return applyActivity(event)
        case .housekeeping:
            // Alive, and nothing more. A subagent finishing is not the parent picking the work back
            // up, so this may not resolve a wait, clear a background pause, or say "working".
            return noteHeardFrom(event)
        case .attention:
            return applyAttention(event)
        }
    }

    /// Fold in the per-session heartbeat files. Ordinary work only reaches the engine this way.
    ///
    /// Non-activity heartbeats refresh terminal identity but deliberately do **not** advance
    /// `lastEventAt`: the matching spool record carries the same timestamp and must not find
    /// itself already considered old by the time it is read.
    @discardableResult
    public func applyHeartbeats(_ beats: [SessionHeartbeat]) -> [EngineEffect] {
        var effects: [EngineEffect] = []
        for beat in beats where beat.schema == SessionHeartbeat.currentSchema {
            guard !beat.identity.sessionID.isEmpty else { continue }
            let signal = AttentionEngine.effectiveSignal(beat.lastSignal, hookEvent: beat.lastHookEvent)
            if signal == .activity || signal == .housekeeping {
                // Housekeeping has no spool record of its own, so the heartbeat is the *only* place
                // a subagent's proof of life arrives. It has to be ingested — otherwise the parent's
                // last-seen never advances and a session first heard of through a child would be
                // dropped entirely. Deterministic id: re-reading the same unchanged heartbeat is a
                // no-op, however many times the file is polled.
                let id = "hb:\(beat.identity.sessionID):\(beat.lastEventAt.timeIntervalSince1970)"
                effects += ingest(EmittedEvent(
                    id: id,
                    hookEvent: beat.lastHookEvent,
                    signal: signal,
                    occurredAt: beat.lastEventAt,
                    identity: beat.identity
                ))
            } else if var session = sessionStates[beat.identity.sessionID] {
                session.identity = merged(beat.identity, over: session.identity)
                session.hasHookEvidence = true
                sessionStates[beat.identity.sessionID] = session
            }
        }
        return effects
    }

    private func applySessionStart(_ event: EmittedEvent) -> [EngineEffect] {
        // A replayed start must not clear an alert raised after it.
        if let existing = sessionStates[event.sessionID], event.occurredAt < existing.lastEventAt {
            return []
        }

        // A session starting — including `claude --resume`, which reuses the id — is the *agent*
        // coming back, not the user answering. An acceptance checkpoint outlives it.
        let keptCheckpoint = sessionStates[event.sessionID]?.currentItemID
            .flatMap { storage[$0] }?.awaitsUserAcceptance == true
        let effects = resolveItem(forSession: event.sessionID, reason: .sessionResumedWork,
                                  userResponded: false)
        var session = sessionStates[event.sessionID] ?? newSession(for: event, activity: .unknown)
        session.identity = merged(event.identity, over: session.identity)
        session.hasHookEvidence = true
        // A client that just opened is sitting at its prompt. That is not evidence it is working,
        // so nothing — least of all a stall — may be inferred from it.
        session.activity = .unknown
        session.lastEventAt = max(session.lastEventAt, event.occurredAt)
        session.lastActivityAt = max(session.lastActivityAt, event.occurredAt)
        session.backgroundSupersededAt = event.occurredAt
        // A checkpoint the resolve step deliberately kept must stay *attached*. Clearing the
        // current item here left it in the queue with nothing pointing at it, so the next signal
        // raised a second row beside it — one wait shown as two, and the orphan clearable only by
        // a user reply or the session dying.
        if !keptCheckpoint {
            session.currentItemID = nil
            session.episodeID = UUID().uuidString
            session.episodeDismissed = false
        }
        sessionStates[event.sessionID] = session
        return effects
    }

    private func applySessionEnd(_ event: EmittedEvent) -> [EngineEffect] {
        // A replayed end must not drop a session that has since restarted under the same id
        // (`claude --resume` reuses it).
        if let existing = sessionStates[event.sessionID], event.occurredAt < existing.lastEventAt {
            return []
        }

        // The session ending is not an answer either. The ask was put to a person, and it stays
        // in the queue as a record of something nobody replied to until they dismiss it.
        // The conversation is over: nothing can be replied to in it, so nothing is kept for a
        // reply that can never come.
        var effects = resolveItem(forSession: event.sessionID, reason: .sessionEnded,
                                  userResponded: false, sessionSurvives: false)
        if sessionStates.removeValue(forKey: event.sessionID) != nil {
            effects.append(.sessionDropped(sessionID: event.sessionID, reason: .sessionEnded))
        }
        return effects
    }

    private func applyActivity(_ event: EmittedEvent) -> [EngineEffect] {
        // Out-of-order or replayed activity must never clear a newer attention item. Timestamps
        // carry milliseconds, so a tool finishing in the same second as the ask that produced it
        // still compares as newer.
        if let existing = sessionStates[event.sessionID], event.occurredAt <= existing.lastEventAt {
            var refreshed = existing
            refreshed.identity = merged(event.identity, over: existing.identity)
            refreshed.hasHookEvidence = true
            sessionStates[event.sessionID] = refreshed
            return []
        }

        // `UserPromptSubmit` is the one activity that *is* the user: they typed something back.
        // Everything else here is the agent working, which resolves an ordinary wait and leaves an
        // acceptance checkpoint exactly where it was.
        let userResponded = event.hookEvent == "UserPromptSubmit"
        let effects = resolveItem(forSession: event.sessionID, reason: .sessionResumedWork,
                                  userResponded: userResponded)
        var session = sessionStates[event.sessionID] ?? newSession(for: event, activity: .working)
        session.identity = merged(event.identity, over: session.identity)
        session.hasHookEvidence = true
        // Real work supersedes a background pause; the reading itself is kept, since tasks outlive
        // the turn that started them.
        session.activity = .working
        session.lastEventAt = max(session.lastEventAt, event.occurredAt)
        session.lastActivityAt = max(session.lastActivityAt, event.occurredAt)
        // The last `Stop` reading described the turn that has just been superseded. It is kept for
        // the record, but it can no longer confirm a completion: without this, a bare
        // `agent_completed` arriving later would reuse it and manufacture a milestone.
        session.backgroundSupersededAt = event.occurredAt
        // An acceptance checkpoint that survived stays *attached*: clearing the current item or
        // opening a new episode here would leave it in the queue with nothing pointing at it, and
        // the next signal would raise a duplicate beside it.
        let keptCheckpoint = session.currentItemID.flatMap { storage[$0] }?.awaitsUserAcceptance == true
            && !userResponded
        if !keptCheckpoint {
            session.currentItemID = nil
            // Real work closes the episode: a later ask is a genuinely new one, and a dismissal
            // from the old episode no longer describes anything.
            session.episodeID = UUID().uuidString
            session.episodeDismissed = false
        }
        sessionStates[event.sessionID] = session
        return effects
    }

    private func applyAttention(_ event: EmittedEvent) -> [EngineEffect] {
        guard var kind = event.attentionKind else { return [] }
        // Inferred inactivity is no longer a thing this app reports. A record from an older build,
        // or a replayed spool file, carries no evidence about anything — so it records that we
        // heard from the session and changes nothing else. It must never turn a working session,
        // or one with an open question, into "waiting for you".
        if kind == .suspectedStall { return noteHeardFrom(event) }

        // An ask that predates the session's most recent real work belongs to a closed episode.
        if let existing = sessionStates[event.sessionID], event.occurredAt < existing.lastActivityAt {
            return []
        }

        var detail = event.detail?.isEmpty == false ? event.detail! : kind.staticDetail
        var session = sessionStates[event.sessionID] ?? newSession(for: event, activity: .awaitingUser)
        session.identity = merged(event.identity, over: session.identity)
        session.hasHookEvidence = true
        session.lastEventAt = max(session.lastEventAt, event.occurredAt)

        // A `Stop` carries the only structured statement we get about what the turn left running.
        // A fresh reading also clears the mark left by work that superseded the previous one.
        if let background = event.background {
            session.background = background
            session.backgroundSupersededAt = nil
            // The snapshot also names the jobs. They go into the registry, which is a separate
            // account from the counts above: the counts describe this reading, the registry
            // describes what this session is known to have running.
            session.jobs.apply(snapshot: background, ownedBy: session.identity.sessionID)
        }
        let certainty = session.completionCertainty(
            at: event.occurredAt, ttl: config.backgroundEvidenceTTLSeconds)
        // Does a real ask already govern this session? A pause never displaces one.
        let hasLiveAsk = session.currentItemID
            .flatMap { storage[$0] }
            .map { !$0.kind.isGeneric } ?? false

        // Whether the user wants to *see* this class of generic signal. It is a preference about
        // alerts, and nothing more: switching it off must not stop the app reconciling what it
        // knows, and must not hide a genuine failure.
        let alertAllowed: Bool = {
            switch kind {
            case .workComplete: return config.notifyOnWorkComplete
            case .idle: return config.notifyOnIdle
            default: return true
            }
        }()

        if kind.isGeneric {
            if let background = session.background, background.hasFailure, event.background != nil {
                // A failed background task is the one thing here that genuinely needs a human. It
                // must not be filed as a completion, must not hide behind a quiet pause while other
                // tasks carry on running, and is not what "turn off completion alerts" asked for.
                kind = .error
                detail = background.summaryLine
            } else if (!certainty.supportsCompletionAlert || !alertAllowed) && !hasLiveAsk {
                // Everything else generic — a turn that paused, an older Claude Code, an unreadable
                // payload, a reading that has gone stale, an `agent_completed` carrying no
                // structured evidence at all, or an idle prompt following any of those. None of it
                // is a request, so none of it may produce a badge, a card or a spoken alert.
                //
                // It also has to *undo* an earlier generic item: a completion card raised a minute
                // ago is contradicted by a `Stop` that now says work is still running.
                //
                // (When a real ask is already open this branch is skipped: the signal falls through
                // and folds into that card as another sighting of the same wait. Counting a repeat
                // is not manufacturing urgency — the card is already there, and its rank keeps the
                // ask's own description.)
                var effects: [EngineEffect] = []
                if let id = session.currentItemID, let superseded = storage[id], superseded.kind.isGeneric {
                    storage[id] = nil
                    session.currentItemID = nil
                    effects.append(.resolved(itemID: superseded.id, reason: .evidenceWithdrawn))
                }
                // The state is what the evidence says, whether or not we are allowed to alert about
                // it. A suppressed *confirmed* completion still means the turn finished.
                switch certainty {
                case .confirmed: session.activity = .awaitingUser
                case .paused: session.activity = .backgroundWaiting
                case .uncertain: session.activity = .unknown
                }
                sessionStates[event.sessionID] = session
                return effects
            } else if let background = session.background, event.background != nil,
                      certainty.supportsCompletionAlert {
                // Confirmed. It may be shown, and it says only what the evidence supports.
                detail = background.summaryLine
            }
        }

        // A real ask is actionable whatever is running behind it — being busy is not a reason to
        // sit on a permission prompt, and a paused session that asks you something is now waiting
        // on *you*.
        session.activity = .awaitingUser

        // The user has already dealt with this wait. Claude Code will keep describing it; we stay
        // quiet until the session actually does something.
        if session.episodeDismissed {
            sessionStates[event.sessionID] = session
            return []
        }

        if let currentID = session.currentItemID, var existing = storage[currentID] {
            // Same episode: fold in rather than raising again.
            existing.lastSeenAt = max(existing.lastSeenAt, event.occurredAt)
            existing.occurrences += 1
            existing.identity = event.identity
            // Acceptance is **sticky through a merge**. It says who can close this item, not how
            // loud it is — so a later signal folding into the same episode must not quietly turn a
            // checkpoint back into an ordinary wait that the agent's next tool call clears.
            existing.awaitsUserAcceptance = existing.awaitsUserAcceptance || event.awaitsUserAcceptance
            if kind.rank > existing.kind.rank {
                existing.kind = kind
                existing.detail = detail
                existing.source = event.source
            }
            storage[currentID] = existing
            sessionStates[event.sessionID] = session
            return [.repeated(existing)]
        }

        let item = AttentionItem(
            sessionID: event.sessionID,
            episodeID: session.episodeID,
            kind: kind,
            source: event.source,
            detail: detail,
            firstSeenAt: event.occurredAt,
            lastSeenAt: event.occurredAt,
            identity: event.identity,
            awaitsUserAcceptance: event.awaitsUserAcceptance
        )
        storage[item.id] = item
        session.currentItemID = item.id
        sessionStates[event.sessionID] = session
        return [.raised(item)]
    }

    /// Note that a hook arrived, and change nothing else.
    ///
    /// For a signal that asserts nothing we can stand behind. It updates identity and the last-seen
    /// clock — both are just facts about the delivery — and leaves activity, the open item and the
    /// background reading exactly as they were. A new session created here starts at `.unknown`,
    /// because a signal carrying no evidence cannot establish that anyone is waiting for you.
    private func noteHeardFrom(_ event: EmittedEvent) -> [EngineEffect] {
        var session = sessionStates[event.sessionID] ?? newSession(for: event, activity: .unknown)
        session.identity = merged(event.identity, over: session.identity)
        session.hasHookEvidence = true
        session.lastEventAt = max(session.lastEventAt, event.occurredAt)
        sessionStates[event.sessionID] = session
        return []
    }

    /// A hook wins on every field it has an opinion about; anything it is silent on keeps whatever
    /// we already knew — a registry title, a branch from the transcript.
    private func merged(_ authoritative: SessionIdentity, over existing: SessionIdentity) -> SessionIdentity {
        var result = authoritative
        result.fillGaps(from: existing)
        return result
    }

    // MARK: - Branch facts

    /// Record a branch reading taken from a session's working directory.
    ///
    /// It updates one field and nothing else: not `cwd`, not the activity, not the queue. A reading
    /// is discarded unless it was taken at the directory the session is *currently* in, so a probe
    /// that finished after the session moved cannot label the new directory with the old branch.
    ///
    /// It overrides the transcript's `gitBranch` deliberately, and for hook-covered sessions too:
    /// the transcript stamps that field once at session start and never revisits it, so a session
    /// that moved into a worktree afterwards carries the branch it launched on.
    @discardableResult
    public func apply(branch fact: BranchFact, sessionID: String) -> Bool {
        guard var session = sessionStates[sessionID] else { return false }
        guard !session.identity.cwd.isEmpty, fact.path == session.identity.cwd else { return false }
        // A newer reading wins; an older one that arrived late does not.
        if let existing = session.identity.branch, existing.readAt > fact.readAt { return false }
        session.identity.branch = fact
        sessionStates[sessionID] = session
        return true
    }

    /// Sessions whose branch has not been read, or was read longer ago than `staleAfter`.
    public func sessionsNeedingBranchRead(at now: Date, staleAfter: TimeInterval) -> [SessionState] {
        sessionStates.values
            .filter { !$0.identity.cwd.isEmpty }
            .filter { session in
                guard let branch = session.identity.branch else { return true }
                if branch.path != session.identity.cwd { return true }
                return now.timeIntervalSince(branch.readAt) > staleAfter
            }
            .sorted { $0.identity.sessionID < $1.identity.sessionID }
    }

    // MARK: - Discovery

    /// Fold in the sessions a registry scan found.
    ///
    /// A discovery is not an event. It establishes that a session *exists* and nothing else: no
    /// activity, no attention, no stall, and it is never counted as working. Registry `status`
    /// is carried verbatim for display and never interpreted — it goes stale by design.
    ///
    /// Hooks always win. A discovery fills gaps in what we know and touches nothing else, so a
    /// worktree a hook reported is never overwritten by the directory the session was launched in,
    /// and a snoozed or dismissed card is never disturbed by a re-scan.
    ///
    /// Returns the number of sessions seen here for the first time.
    @discardableResult
    public func apply(discovery report: DiscoveryReport, at now: Date) -> Int {
        var added = 0

        for found in report.verified {
            let id = found.record.sessionID
            guard !id.isEmpty else { continue }

            let discovery = SessionDiscovery(
                discoveredAt: now,
                registryUpdatedAt: found.record.updatedAt,
                registryStatus: found.record.status,
                version: found.record.version
            )

            if var existing = sessionStates[id] {
                if existing.hasHookEvidence {
                    // A hook has spoken for this session. The registry may only fill blanks —
                    // except for the session's *name*, which is the one thing the registry is the
                    // authority on and which a person can legitimately change mid-session. That is
                    // taken by identity and freshness, and touches nothing else: not the working
                    // directory, not the branch, because the registry records where a session was
                    // launched rather than where it is now.
                    existing.identity.fillGaps(from: found.identity)
                    existing.identity.refreshTitle(
                        from: found.identity,
                        scannedAt: found.record.updatedAt ?? now,
                        holdingSince: existing.discovery?.registryUpdatedAt ?? .distantPast
                    )
                } else {
                    // Nothing but the registry knows this one, so a newer scan is the better
                    // record — a session that has moved into a worktree since it was launched
                    // should stop being labelled with the directory it started in.
                    existing.identity.adoptDiscovered(found.identity)
                }
                existing.discovery = discovery
                sessionStates[id] = existing
                continue
            }

            // `lastEventAt` means "when a hook last spoke". A discovery is not a hook, so it stays
            // at the sentinel: otherwise a real hook emitted a moment *before* this scan, but
            // consumed after it, would be thrown away as stale by the ordering guards.
            sessionStates[id] = SessionState(
                identity: found.identity,
                activity: .discovered,
                lastEventAt: .distantPast,
                lastActivityAt: .distantPast,
                hasHookEvidence: false,
                discovery: discovery
            )
            added += 1
        }

        // A record that has gone means a discovered-only session has gone — but only if the scan
        // was in a position to see it. A missing registry, or a refused process inspection, is not
        // evidence of anything.
        if report.isAuthoritative {
            let present = Set(report.verified.map(\.record.sessionID))
            // A record we were refused permission to check is not a record that has gone. Keeping
            // it is the honest answer; it will age out on staleness if it really has.
            let undecided = report.unverifiableSessionIDs
            for (id, session) in sessionStates
            where session.isDiscoveredOnly && !present.contains(id) && !undecided.contains(id) {
                sessionStates.removeValue(forKey: id)
            }
        }

        return added
    }

    private func newSession(for event: EmittedEvent, activity: SessionActivityState) -> SessionState {
        SessionState(
            identity: event.identity,
            activity: activity,
            lastEventAt: event.occurredAt,
            lastActivityAt: event.occurredAt
        )
    }

    // MARK: - User actions

    @discardableResult
    public func snooze(itemID: String, for interval: TimeInterval? = nil) -> Bool {
        guard var item = storage[itemID] else { return false }
        let length = max(1, interval ?? config.snoozeDurationSeconds)
        item.snoozedUntil = clock.now.addingTimeInterval(length)
        storage[itemID] = item
        return true
    }

    @discardableResult
    public func dismiss(itemID: String) -> [EngineEffect] {
        guard let item = storage.removeValue(forKey: itemID) else { return [] }
        if var session = sessionStates[item.sessionID], session.currentItemID == itemID {
            session.currentItemID = nil
            // Everything else Claude Code says about this same wait stays quiet.
            session.episodeDismissed = true
            sessionStates[item.sessionID] = session
        }
        return [.resolved(itemID: itemID, reason: .dismissed)]
    }

    @discardableResult
    public func dismissAll() -> [EngineEffect] {
        allItems().flatMap { dismiss(itemID: $0.id) }
    }

    // MARK: - Sweep

    /// Periodic maintenance: unsnooze, expire, retire evidence that has aged out, check liveness,
    /// drop stale records. It never *creates* an attention item — nothing here is a signal.
    @discardableResult
    public func sweep() -> [EngineEffect] {
        let now = clock.now
        var effects: [EngineEffect] = []

        // 0. A background reading that has aged past its TTL stops being a claim about now. The
        // session goes quietly to unknown rather than staying "paused" on a snapshot from an hour
        // ago — and, because it is now uncertain rather than confirmed, a later idle prompt still
        // cannot turn it into an alert.
        for (id, session) in sessionStates where session.activity == .backgroundWaiting {
            guard let background = session.background,
                  background.isStale(at: now, after: config.backgroundEvidenceTTLSeconds) else { continue }
            var aged = session
            aged.activity = .unknown
            sessionStates[id] = aged
        }

        // 1. Snoozes that have run out come back once.
        for item in sorted(Array(storage.values)) {
            guard let until = item.snoozedUntil, until <= now else { continue }
            var updated = item
            updated.snoozedUntil = nil
            storage[item.id] = updated
            effects.append(.unsnoozed(updated))
        }

        // 2. Items nobody dealt with for hours are noise, not signal.
        //
        // With one exception, and it is the whole point of an acceptance checkpoint: an ask put to
        // the user does not answer itself by getting old. A card saying "please test this" that
        // quietly disappears overnight is worse than no card — the work was handed over and nobody
        // ever said anything about it. Only a reply or a dismissal closes one.
        for item in sorted(Array(storage.values)) where !item.awaitsUserAcceptance
            && now.timeIntervalSince(item.firstSeenAt) > config.maxItemAgeSeconds {
            storage.removeValue(forKey: item.id)
            if var session = sessionStates[item.sessionID], session.currentItemID == item.id {
                session.currentItemID = nil
                sessionStates[item.sessionID] = session
            }
            effects.append(.resolved(itemID: item.id, reason: .expired))
        }

        // 3. Liveness and staleness.
        for (id, session) in sessionStates.sorted(by: { $0.key < $1.key }) {
            var drop: EngineEffect.DropReason?

            if let pid = session.identity.claudePID {
                if !liveness.isAlive(pid: pid, startedAt: session.identity.claudePIDStartedAt) {
                    drop = .processGone
                }
            }
            // A discovered-only session has never had a hook event, so its clock is the last scan
            // that found it.
            let lastKnown = max(session.lastEventAt, session.discovery?.discoveredAt ?? .distantPast)
            if drop == nil, now.timeIntervalSince(lastKnown) > config.staleSessionSeconds {
                drop = .stale
            }

            guard let reason = drop else { continue }
            // A process going away, or a record ageing out, says nothing about whether the user
            // looked at what they were handed.
            effects += resolveItem(
                forSession: id,
                reason: reason == .processGone ? .processGone : .expired,
                userResponded: false,
                sessionSurvives: false          // the record is removed on the next line
            )
            sessionStates.removeValue(forKey: id)
            effects.append(.sessionDropped(sessionID: id, reason: reason))
        }

        // Inferred stalls used to live here. They are gone on purpose: legitimate work runs for
        // hours, and elapsed silence is not evidence of anything. Nothing in this app turns the
        // passage of time into an alert, a badge, a sound or a queue item.

        return effects
    }

    // MARK: - Helpers

    private func resolveItem(forSession sessionID: String, reason: EngineEffect.ResolutionReason,
                             userResponded: Bool = true,
                             sessionSurvives: Bool = true) -> [EngineEffect] {
        /// An acceptance checkpoint asked the *user* to try something. The session going back to
        /// work is not that: the agent carrying on, a shell finishing, a monitor ticking — none of
        /// it is evidence anybody looked. Only the user's own reply, or a dismissal, closes one.
        ///
        /// **Unless the session itself is going.** The evidence that closes one of these is a reply
        /// *in that conversation*, so once the record is removed no such evidence can ever arrive
        /// and the item would sit in the count for ever. That is what was seen on the installed
        /// build: an ask from a session that had already been dropped, still counted forty minutes
        /// later, with nothing in the world able to clear it.
        func keeps(_ item: AttentionItem?) -> Bool {
            guard sessionSurvives else { return false }
            guard let item, item.awaitsUserAcceptance, !userResponded else { return false }
            return true
        }

        guard var session = sessionStates[sessionID], let itemID = session.currentItemID else {
            // Also cover items whose session link was lost.
            let orphans = storage.values.filter { $0.sessionID == sessionID && !keeps($0) }
            guard !orphans.isEmpty else { return [] }
            return orphans.map { orphan in
                storage.removeValue(forKey: orphan.id)
                return .resolved(itemID: orphan.id, reason: reason)
            }
        }
        guard !keeps(storage[itemID]) else { return [] }
        session.currentItemID = nil
        sessionStates[sessionID] = session
        guard storage.removeValue(forKey: itemID) != nil else { return [] }
        return [.resolved(itemID: itemID, reason: reason)]
    }

    private func rememberEventID(_ id: String) {
        recentEventIDs.append(id)
        recentEventIDSet.insert(id)
        if recentEventIDs.count > recentEventIDLimit {
            let overflow = recentEventIDs.count - recentEventIDLimit
            let removed = recentEventIDs.prefix(overflow)
            recentEventIDs.removeFirst(overflow)
            for old in removed where !recentEventIDs.contains(old) {
                recentEventIDSet.remove(old)
            }
        }
    }
}
