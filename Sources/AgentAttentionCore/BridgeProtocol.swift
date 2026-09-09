import Foundation

/// The wire format between a bridge client and the Warden-owned bridge host.
///
/// One JSON object per line, in both directions. Deliberately small: a caller can only start a
/// session Warden owns, send a message to one, ask what has happened, or stop one. There is no verb
/// for "attach to that terminal over there", because that is not a thing this can honestly do.
public enum BridgeProtocol {
    public static let version = 1
    /// A frame larger than this is refused, not truncated: a half-read command is worse than none.
    public static let maximumFrameBytes = 256 * 1024
    /// A prompt longer than this is refused. Bounded because everything here is bounded.
    public static let maximumPromptBytes = 32 * 1024
    /// How many sessions one host will own at once.
    public static let maximumSessions = 8
    /// Events kept per session. Beyond this the oldest are dropped and the gap is *reported*.
    public static let maximumRetainedEvents = 2_000
    /// Events returned in one response. A frame that would not fit is paged, with a cursor, rather
    /// than truncated into something a caller would read as complete.
    public static let maximumEventsPerResponse = 100
    /// Messages remembered per session, and start requests remembered per host. Bounded like
    /// everything else: an unbounded array is an unbounded memory bug waiting for a busy caller.
    public static let maximumMessagesPerSession = 200
    public static let maximumStartRequests = 200
    /// Caller-supplied identifiers are short, printable and bounded.
    public static let maximumIdentifierLength = 128
    /// The most text kept on one event. Bounded here rather than at each call site.
    public static let maximumEventTextLength = 4_000
    /// The budget one encoded response may occupy. Well under the frame limit, because the frame
    /// limit is what the *reader* refuses — a response that reached it would simply be lost.
    public static let maximumResponseBytes = 192 * 1024
    /// Messages included in a session state on the wire. The rest are counted, not sent.
    public static let maximumMessagesPerResponse = 40
    /// Result identities remembered per session, so the same answer cannot settle two turns.
    ///
    /// Tied to the message bound on purpose. One result settles one turn, and a session will never
    /// accept more than `maximumMessagesPerSession` turns — so this remembers every answer for the
    /// whole life of a session while still being a fixed, bounded store. A smaller number would let
    /// an old identity be forgotten *while new prompts were still being accepted*, and a replayed
    /// answer from before the window could then settle a turn sent after it.
    public static let maximumSettledResults = maximumMessagesPerSession
}

/// What a caller can ask for.
public enum BridgeRequest: Codable, Sendable, Equatable {
    /// Start a new session Warden owns, in an approved directory.
    case start(StartRequest)
    /// Send a prompt to a session this host started. The first and every later turn use this.
    case send(SendRequest)
    /// What is the state of one session, or of all of them?
    case status(sessionID: String?)
    /// Everything recorded after `afterSequence`, with any dropped range reported.
    case events(sessionID: String, afterSequence: Int)
    /// Stop a session this host started. Never touches anything else.
    case stop(sessionID: String)
    /// Bring a visible session's own terminal to the front. Only a surface this host created.
    case focus(sessionID: String)
    /// Ask the running app to enter roam — the lid-closed keep-awake session.
    ///
    /// Unlike every verb above, this is not about a session this host started: it is answered by
    /// a host running *inside* Agent Warden itself, which is the only thing that can actually hold
    /// roam open (see `aa-roam`'s own doc for why a short-lived caller cannot). A bare
    /// `aa-bridge serve`, which owns no `RoamService`, refuses it with `.unsupported`.
    case roamOn
    /// Ask the running app to leave roam. A no-op, reported as such, when roam was already off.
    case roamOff

    public struct StartRequest: Codable, Sendable, Equatable {
        /// Caller-chosen id, so a retry cannot start two sessions. Reusing it with *different*
        /// intent is a conflict, not a retry.
        public var requestID: String
        public var cwd: String
        public var model: String?
        /// Where the session should run. Absent — the default — is the original background client
        /// with pipes, unchanged. `"ghostty"` opens a visible tab the user can watch.
        public var terminal: String?

        public init(requestID: String, cwd: String, model: String? = nil, terminal: String? = nil) {
            self.requestID = requestID
            self.cwd = cwd
            self.model = model
            self.terminal = terminal
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try c.decode(String.self, forKey: .requestID)
            cwd = try c.decode(String.self, forKey: .cwd)
            model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
            // A request written before visible sessions existed asks for the background client,
            // which is what it always got.
            terminal = ((try? c.decodeIfPresent(String.self, forKey: .terminal)) ?? nil)
        }

        /// Everything that makes this request what it is, in a stable form. A retry must match all
        /// of it — and the comparison must mean the same thing in the next process, which is why
        /// this is a digest of an explicit serialisation rather than of an interpolated string.
        var intentFingerprint: String {
            // The surface is part of the intention: the same request id asking for a visible
            // session is not a retry of one that asked for a background client.
            let parts = ["v1", "cwd=\(BridgeHost.resolve(cwd) ?? cwd)", "model=\(model ?? "")",
                         "terminal=\(terminal ?? "")"]
            return BridgeHost.fingerprint(parts.joined(separator: "\u{1}"))
        }
    }

    public struct SendRequest: Codable, Sendable, Equatable {
        public var sessionID: String
        /// Caller-chosen and stable. The same id with the same text is a no-op; the same id with
        /// *different* text is a conflict and is refused.
        public var messageID: String
        public var prompt: String
        public init(sessionID: String, messageID: String, prompt: String) {
            self.sessionID = sessionID
            self.messageID = messageID
            self.prompt = prompt
        }
    }
}

/// What the host answers.
public struct BridgeResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    /// Present when `ok` is false. A refusal always says which rule refused it.
    public var error: BridgeError?
    public var session: BridgeSessionState?
    public var sessions: [BridgeSessionState]?
    public var events: [BridgeEvent]?
    /// Events that were dropped before `events` begins, so a caller is never quietly short.
    public var droppedBefore: Int?
    /// More events exist after the ones returned. Ask again from `nextAfter`.
    public var moreAvailable: Bool?
    public var nextAfter: Int?
    public var version: Int
    /// A plain sentence for a verb that has nothing structured to report. Only `roamOn` and
    /// `roamOff` set it today — every session verb answers through `session`/`sessions` instead,
    /// which is why this is a separate field rather than an overload of an existing one.
    public var message: String?

    public init(ok: Bool, error: BridgeError? = nil, session: BridgeSessionState? = nil,
                sessions: [BridgeSessionState]? = nil, events: [BridgeEvent]? = nil,
                droppedBefore: Int? = nil, moreAvailable: Bool? = nil, nextAfter: Int? = nil,
                version: Int = BridgeProtocol.version, message: String? = nil) {
        self.ok = ok
        self.error = error
        self.session = session
        self.sessions = sessions
        self.events = events
        self.droppedBefore = droppedBefore
        self.moreAvailable = moreAvailable
        self.nextAfter = nextAfter
        self.version = version
        self.message = message
    }
}

public struct BridgeError: Codable, Sendable, Equatable, Error {
    public var code: Code
    public var message: String

    public enum Code: String, Codable, Sendable, Equatable {
        /// The frame could not be read, or is too big.
        case malformed
        /// A session id this host did not create. **Never** adopted, whatever it names.
        case notOwned
        /// The same message id with different content.
        case idempotencyConflict
        /// A bound was hit: sessions, prompt size, frame size.
        case limitReached
        /// The directory is not one this host will start a session in.
        case directoryNotApproved
        /// The client could not be started, or died before it acknowledged anything.
        case clientUnavailable
        /// A turn is already in flight for this session. One at a time, so a result can only ever
        /// belong to one request.
        case busy
        /// Claude Code refused a permission and the host has no way to answer it.
        case permissionUnsupported
        case unknownRequest
        /// This host has no capability to do what was asked, at all — not a policy refusal, a
        /// missing one. `roamOn`/`roamOff` answered by a host with no `RoamBridgeControlling`
        /// (a bare `aa-bridge serve`, which holds no `RoamService`) land here.
        case unsupported
        /// The request was understood and could be answered, and the answer is no. The message
        /// says why. Kept apart from `clientUnavailable`, which names a *process* that is gone:
        /// this is a decision made by something that is very much present — the battery guard
        /// refusing roam, or the power daemon refusing a foreign or busy lease.
        case refused
    }

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

/// Where one owned session has got to.
///
/// The states are kept apart on purpose. "We wrote the prompt to a pipe" is not "the client has it";
/// "the client has it" is not "it did the work"; and a disconnect is neither a success nor a
/// failure — it is *uncertain*, and saying so is the whole point.
public enum BridgeSessionPhase: String, Codable, Sendable, Equatable {
    /// The host has the request and a process is being started.
    case accepted
    /// The client echoed the user message back (`--replay-user-messages`). This is the only
    /// evidence that it received anything; a successful pipe write is not.
    case clientAcknowledged
    /// The client is working: assistant text, tool calls, or any other stream activity.
    case active
    /// A turn produced its final result.
    case completed
    /// The client reported an error, or exited non-zero.
    case failed
    /// The client went away, or a deadline passed, without a result. Nothing is resent
    /// automatically: an ambiguous retry is how one instruction becomes two.
    case uncertain
    /// A stop was **asked for**, and the process has not confirmed it yet. Kept apart from
    /// `stopped` for the same reason `accepted` is kept apart from `clientAcknowledged`: sending a
    /// signal is not the same as the process having gone, and reporting one as the other is how a
    /// host announces a clean shutdown over a child that is still alive.
    case stopping
    /// The process this host started is **confirmed gone** after a stop. Only an observed exit —
    /// never our own intent — turns `stopping` into this.
    case stopped
}

public struct BridgeSessionState: Codable, Sendable, Equatable {
    public var sessionID: String
    /// The id the client itself reports, once it says one. Compared with `sessionID`, so a caller
    /// can see they are the same session rather than being told so.
    public var clientReportedSessionID: String?
    public var cwd: String
    public var phase: BridgeSessionPhase
    public var pid: Int32?
    public var startedAt: Date
    public var lastEventAt: Date?
    /// Per-message state, in the order the caller sent them.
    public var messages: [BridgeMessageState]
    /// Highest event sequence recorded so far.
    public var lastSequence: Int
    /// Non-nil once the process has gone.
    public var exitStatus: Int32?
    /// Set when the host refused, or could not answer, a permission prompt.
    public var permissionNote: String?
    /// Background jobs this session is known to have, each named by session **and** task id.
    /// Reported apart from the turn's phase, because "the turn is finished" and "nothing is running
    /// behind it" are different claims.
    public var jobs: [BridgeJobState]
    /// How complete the job list is: `unknown`, `partial` or `observed`. Never all of them — a
    /// stream can drop frames and an older client emits none.
    public var jobCoverage: String
    /// Jobs dropped to stay inside the bound. Any at all means this list is not the whole list.
    public var jobsOmitted: Int
    /// What the session's main turn is doing, as opposed to what happened to our last message.
    public var parent: BridgeParentActivity?
    /// An open ask this session has put to the user.
    public var attention: BridgeAttentionState?
    /// The visible terminal this session runs in, when it was started with one. Absent for the
    /// default background client.
    public var surface: BridgeSurfaceState?
    /// The last time this session did work nobody prompted: a monitor woke it, a task reported
    /// back, and it carried on. Observed and reported; never treated as an answer to a prompt.
    public var autonomousActivityAt: Date?
    /// Messages this session holds that did not fit in this answer. Present rather than implied, so
    /// a caller is never handed a short list that looks complete.
    public var messagesOmitted: Int?

    public init(sessionID: String, clientReportedSessionID: String? = nil, cwd: String,
                phase: BridgeSessionPhase, pid: Int32? = nil, startedAt: Date,
                lastEventAt: Date? = nil, messages: [BridgeMessageState] = [],
                lastSequence: Int = 0, exitStatus: Int32? = nil, permissionNote: String? = nil,
                messagesOmitted: Int? = nil, jobs: [BridgeJobState] = [],
                jobCoverage: String = BackgroundRegistry.Coverage.unknown.rawValue,
                jobsOmitted: Int = 0, parent: BridgeParentActivity? = nil,
                attention: BridgeAttentionState? = nil, surface: BridgeSurfaceState? = nil,
                autonomousActivityAt: Date? = nil) {
        self.sessionID = sessionID
        self.clientReportedSessionID = clientReportedSessionID
        self.cwd = cwd
        self.phase = phase
        self.pid = pid
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.messages = messages
        self.lastSequence = lastSequence
        self.exitStatus = exitStatus
        self.permissionNote = permissionNote
        self.messagesOmitted = messagesOmitted
        self.jobs = jobs
        self.jobCoverage = jobCoverage
        self.jobsOmitted = jobsOmitted
        self.parent = parent
        self.attention = attention
        self.surface = surface
        self.autonomousActivityAt = autonomousActivityAt
    }
}

/// The visible terminal a session was started in.
public struct BridgeSurfaceState: Codable, Sendable, Equatable {
    /// `ghostty` today. Stated rather than assumed, so a reader knows what the ids belong to.
    public var terminal: String
    /// Exactly what the terminal reported when it created the surface — never matched by title.
    public var windowID: String
    public var tabID: String
    public var terminalID: String
    /// Is the surface still there? A tab the user closed is a session that has gone.
    public var open: Bool
    /// Stated plainly, because a tab that ignores keystrokes otherwise looks broken.
    public var acceptsTyping: Bool
    public var note: String

    public init(terminal: String, windowID: String, tabID: String, terminalID: String,
                open: Bool, acceptsTyping: Bool = false,
                note: String = "Driven by the Agent Warden API. Typing in the tab is not enabled.") {
        self.terminal = terminal
        self.windowID = windowID
        self.tabID = tabID
        self.terminalID = terminalID
        self.open = open
        self.acceptsTyping = acceptsTyping
        self.note = note
    }
}

/// One background job on the wire.
///
/// Freshness is **stated**, not left for a caller to work out from a timestamp and a TTL it would
/// have to know. Everything a consumer needs to decide whether to believe this row is here.
public struct BridgeJobState: Codable, Sendable, Equatable {
    public var sessionID: String
    public var taskID: String
    /// `task` or `cron` — two id spaces, so the same number in each is two different jobs.
    public var namespace: String
    public var kind: String
    public var state: String
    public var source: String
    public var type: String?
    public var toolUseID: String?
    /// Only ever set for a scheduled wakeup that said so. `false` is a one-shot alarm.
    public var recurring: Bool?
    /// Housekeeping the CLI does not present as user work. Reported, and excluded from the counts.
    public var ambient: Bool
    public var observedAt: Date
    /// How long ago that was, at the moment this answer was built.
    public var ageSeconds: Double
    /// Past the host's freshness window. A stale row is history, not a claim about now.
    public var stale: Bool

    public init(sessionID: String, taskID: String, namespace: String = "task", kind: String,
                state: String, source: String, type: String? = nil, toolUseID: String? = nil,
                recurring: Bool? = nil, ambient: Bool = false, observedAt: Date,
                ageSeconds: Double = 0, stale: Bool = false) {
        self.sessionID = sessionID
        self.taskID = taskID
        self.namespace = namespace
        self.kind = kind
        self.state = state
        self.source = source
        self.type = type
        self.toolUseID = toolUseID
        self.recurring = recurring
        self.ambient = ambient
        self.observedAt = observedAt
        self.ageSeconds = ageSeconds
        self.stale = stale
    }
}

/// What the session's **main turn** is doing right now, as distinct from the phase of the last
/// message we sent it.
///
/// `phase` answers "what happened to my prompt". This answers "what is this session doing" — and
/// they are different questions the moment a session starts working on its own.
public struct BridgeParentActivity: Codable, Sendable, Equatable {
    /// `working`, `idle`, `requiresAction` or `unknown`. Only ever what the client itself said, or
    /// unknown.
    public var state: String
    /// When that was reported.
    public var observedAt: Date?
    public var ageSeconds: Double?
    /// The reading is older than the freshness window, so it describes a past moment.
    public var stale: Bool
    /// The last time this session did work nobody prompted.
    public var autonomousActivityAt: Date?
    /// The client process is gone, so nothing here is a claim about now.
    public var clientRunning: Bool
    /// A short sentence for a person or a log.
    public var summary: String

    public init(state: String, observedAt: Date? = nil, ageSeconds: Double? = nil,
                stale: Bool = false, autonomousActivityAt: Date? = nil,
                clientRunning: Bool = true, summary: String) {
        self.state = state
        self.observedAt = observedAt
        self.ageSeconds = ageSeconds
        self.stale = stale
        self.autonomousActivityAt = autonomousActivityAt
        self.clientRunning = clientRunning
        self.summary = summary
    }
}

/// An open ask this owned session has put to the user, kept apart from the turn's phase and from
/// the background registry — the same three-way separation the monitored sessions have.
public struct BridgeAttentionState: Codable, Sendable, Equatable {
    /// The message id whose turn raised it, so a caller can tie it to its own send.
    public var messageID: String?
    /// `acceptance` when the session handed work over for the user to try; `none` otherwise.
    public var kind: String
    /// A bounded excerpt of the request itself. Present only when the host was asked for content.
    public var excerpt: String?
    public var raisedAt: Date?
    /// Still open. **Only** a user response or an explicit resolution clears it — no job event,
    /// no autonomous activity, no later turn.
    public var open: Bool

    public init(messageID: String? = nil, kind: String, excerpt: String? = nil,
                raisedAt: Date? = nil, open: Bool) {
        self.messageID = messageID
        self.kind = kind
        self.excerpt = excerpt
        self.raisedAt = raisedAt
        self.open = open
    }
}

public struct BridgeMessageState: Codable, Sendable, Equatable {
    public var messageID: String
    public var phase: BridgeSessionPhase
    public var sentAt: Date
    public var acknowledgedAt: Date?
    public var completedAt: Date?
    /// A short, bounded digest of what the caller sent. Used to detect a conflicting reuse of an
    /// id; never the prompt itself.
    public var promptFingerprint: String
    /// The identifier written into the message this host sent, and required back in the client's
    /// echo before anything is called acknowledged.
    public var correlationID: String

    public init(messageID: String, phase: BridgeSessionPhase, sentAt: Date,
                acknowledgedAt: Date? = nil, completedAt: Date? = nil,
                promptFingerprint: String, correlationID: String) {
        self.messageID = messageID
        self.phase = phase
        self.sentAt = sentAt
        self.acknowledgedAt = acknowledgedAt
        self.completedAt = completedAt
        self.promptFingerprint = promptFingerprint
        self.correlationID = correlationID
    }
}

/// One thing that happened, in order, with a sequence a caller can resume from.
public struct BridgeEvent: Codable, Sendable, Equatable {
    public var sequence: Int
    public var at: Date
    public var kind: Kind
    /// Free text from the client, already bounded. Present for output and errors.
    public var text: String?
    public var messageID: String?

    public enum Kind: String, Codable, Sendable, Equatable {
        case started
        case acknowledged
        case assistantText
        case toolUse
        case result
        case error
        case exited
        case permission
        case note
    }

    public init(sequence: Int, at: Date, kind: Kind, text: String? = nil, messageID: String? = nil) {
        self.sequence = sequence
        self.at = at
        self.kind = kind
        self.text = text
        self.messageID = messageID
    }
}
