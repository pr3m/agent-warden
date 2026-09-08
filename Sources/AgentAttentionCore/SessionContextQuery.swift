import Foundation

/// The one path to "what is this session working on", used by the command line and the app alike.
///
/// It exists because there were nearly two of them, and the second was weaker: the command line read
/// a transcript for any id that happened to have a file, announced "not in the tracked queue", and
/// exited 0 — which is a way to be shown a conversation the app cannot vouch for at all.
///
/// The order here is the point. **Identity first, contents second.** A transcript is only opened for
/// a session this app already knows about, and what comes back always says how far that knowledge
/// goes: whether the process is alive, whether the queue is fresh enough to trust, and how old the
/// conversation is. Those three are separate questions and are never collapsed into one.
public struct SessionContextAnswer: Codable, Sendable, Equatable {
    /// How sure we are that the id names a session this app is actually tracking.
    public enum Identity: String, Codable, Sendable {
        /// In the queue, with a live process at the recorded start time.
        case verifiedLive
        /// In the queue; its process is confirmed gone. The conversation is history.
        case processGone
        /// In the queue, but the process could not be checked, or none was ever recorded.
        case unverified
        /// Not a session this app is tracking. **No contents are read.**
        case notTracked
    }

    /// What we can say about the session needing you — the same vocabulary `aa-status` uses.
    public struct Attention: Codable, Sendable, Equatable {
        /// True only when the state is one we positively know *and* the queue can be trusted.
        public var known: Bool
        /// `waiting` / `none` / `uncertain` / `awaitingFirstHook`, from the shared report.
        public var certainty: String
        public var kind: String?
        public var reason: String?
        public var waitingSeconds: Int?
        public var occurrences: Int?
        public var snoozed: Bool?
        /// How old the queue is, and whether the app that maintains it is running.
        public var queueIsFresh: Bool
        public var appIsRunning: Bool?
        public var queueAgeSeconds: Double?
        public var unprocessedEvents: Int
        /// Plain sentences about anything that limits the above.
        public var caveats: [String]

        public init(
            known: Bool, certainty: String, kind: String?, reason: String?,
            waitingSeconds: Int?, occurrences: Int?, snoozed: Bool?,
            queueIsFresh: Bool, appIsRunning: Bool?, queueAgeSeconds: Double?,
            unprocessedEvents: Int, caveats: [String]
        ) {
            self.known = known
            self.certainty = certainty
            self.kind = kind
            self.reason = reason
            self.waitingSeconds = waitingSeconds
            self.occurrences = occurrences
            self.snoozed = snoozed
            self.queueIsFresh = queueIsFresh
            self.appIsRunning = appIsRunning
            self.queueAgeSeconds = queueAgeSeconds
            self.unprocessedEvents = unprocessedEvents
            self.caveats = caveats
        }
    }

    public var sessionID: String
    public var identity: Identity
    public var displayName: String?
    public var cwd: String?
    public var branch: String?
    public var branchState: String?
    public var branchSource: String?
    public var branchReadAt: Date?
    public var generatedLabel: String?
    /// `alive` / `dead` / `unknown` / `unidentified`.
    public var process: String
    public var attention: Attention
    /// Absent when identity did not permit reading.
    public var context: SessionContext?
    public var generatedAt: Date

    public init(
        sessionID: String,
        identity: Identity,
        displayName: String? = nil,
        cwd: String? = nil,
        branch: String? = nil,
        branchState: String? = nil,
        branchSource: String? = nil,
        branchReadAt: Date? = nil,
        generatedLabel: String? = nil,
        process: String,
        attention: Attention,
        context: SessionContext?,
        generatedAt: Date
    ) {
        self.sessionID = sessionID
        self.identity = identity
        self.displayName = displayName
        self.cwd = cwd
        self.branch = branch
        self.branchState = branchState
        self.branchSource = branchSource
        self.branchReadAt = branchReadAt
        self.generatedLabel = generatedLabel
        self.process = process
        self.attention = attention
        self.context = context
        self.generatedAt = generatedAt
    }

    /// Did we read a conversation?
    public var readContents: Bool { context?.availability == .read }
}

public enum SessionContextQuery {
    /// Everything the caller needs, in one read-only pass.
    ///
    /// Writes nothing: not the queue, not the spool, not a log. The transcript is opened for reading
    /// and only when identity allows it.
    public static func run(
        sessionID: String,
        store: EventStore,
        config: AttentionConfig,
        claudeHome: URL,
        liveness: LivenessProbing = SystemLiveness(),
        now: Date = Date(),
        reader: (String, URL, Date) -> SessionContext = { SessionContextReader.read(sessionID: $0, claudeHome: $1, now: $2) }
    ) -> SessionContextAnswer {
        // The same report the badge, the panel and `aa-status` are built from. Reusing it is what
        // stops a second, more optimistic idea of "nothing is waiting" growing here.
        let report = StatusReport.build(store: store, config: config, liveness: liveness, now: now)
        let summary = report.sessions.first { $0.sessionID == sessionID }

        let snapshot = store.loadSnapshot()
        let state = snapshot?.sessions[sessionID]
        let item = state?.currentItemID.flatMap { id in snapshot?.items.first { $0.id == id } }

        var caveats: [String] = []
        let certainty = summary?.attention ?? "unknown"
        let process = summary?.process ?? "unidentified"

        // `known` needs two things at once: a state we positively know, and a queue worth believing.
        // A saved ask from an app that is no longer running is still reported — it is a real record —
        // but it is not live certainty, and it does not get to be called known.
        // Identity has to hold up as well. A session whose process is gone, whose start time does
        // not match what we recorded, or that never had one, is not a session we can make claims
        // about — the pid may have been recycled and the transcript may belong to a previous run.
        let hasPinnedProcess = state?.identity.claudePID != nil && state?.identity.claudePIDStartedAt != nil
        let identityIsVerified = summary != nil && process == "alive" && hasPinnedProcess

        let positivelyKnown = certainty == "waiting" || certainty == "none"
        let known = positivelyKnown && report.answerIsTrustworthy && identityIsVerified

        if summary == nil {
            caveats.append("This session is not in Agent Warden's queue, so nothing is known about what it wants.")
        } else if !report.answerIsTrustworthy {
            caveats.append("The queue could not be trusted at the moment of asking; see the app state below.")
        }
        if certainty == "uncertain" {
            caveats.append("This session's turn ended without anything confirming how, so whether it needs you is unknown, not quiet.")
        }
        if certainty == "awaitingFirstHook" {
            caveats.append("This session was found running but has never reported through a hook.")
        }
        if item != nil && !report.app.fresh {
            caveats.append("The request below is a saved record; the app was not running or its queue was stale, so it may already have been dealt with.")
        }
        caveats += report.warnings

        let identity: SessionContextAnswer.Identity = {
            guard summary != nil else { return .notTracked }
            guard hasPinnedProcess else { return .unverified }
            switch process {
            case "alive": return .verifiedLive
            case "dead": return .processGone
            default: return .unverified
            }
        }()

        // Identity first, and it has to be *verified*. Only a session we are tracking, whose Claude
        // process is alive and is the same one we recorded, gets its transcript opened.
        //
        // Reading for the others would be the same mistake in a quieter form: a dead pid may have
        // been recycled, a start time that does not match names a different run, and a session with
        // no recorded process cannot be tied to a transcript at all. Presenting any of those as
        // "what this session is working on" would be presenting a conversation this app cannot
        // vouch for.
        let context: SessionContext? = identity == .verifiedLive ? reader(sessionID, claudeHome, now) : nil
        switch identity {
        case .processGone:
            caveats.append("This session's Claude process is gone, or is not the one that was recorded. Nothing was read: a recycled pid could belong to something else entirely.")
        case .unverified:
            caveats.append("This session's Claude process could not be pinned down — it has no recorded start time, or could not be checked. Nothing was read.")
        case .notTracked, .verifiedLive:
            break
        }
        if let context, context.availability == .read, context.messages.isEmpty {
            caveats.append("No user or assistant text was found in the part of the transcript that was read.")
        }

        let attention = SessionContextAnswer.Attention(
            known: known,
            certainty: certainty,
            kind: item?.kind.rawValue,
            reason: item?.detail,
            waitingSeconds: item.map { max(0, Int(now.timeIntervalSince($0.firstSeenAt))) },
            occurrences: item?.occurrences,
            snoozed: item.map { $0.snoozedUntil != nil },
            queueIsFresh: report.app.fresh,
            appIsRunning: report.app.running,
            queueAgeSeconds: report.app.stateAgeSeconds,
            unprocessedEvents: report.app.unprocessedEvents,
            caveats: caveats
        )

        return SessionContextAnswer(
            sessionID: sessionID,
            identity: identity,
            displayName: state?.identity.displayName,
            cwd: state?.identity.cwd,
            branch: state?.identity.branchFact?.branch,
            branchState: state?.identity.branchFact?.state,
            branchSource: state?.identity.branchFact?.source,
            branchReadAt: state?.identity.branchFact?.readAt,
            generatedLabel: state?.identity.generatedLabel,
            process: process,
            attention: attention,
            context: context,
            generatedAt: now
        )
    }
}
