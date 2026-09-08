import Foundation

// MARK: - What kind of attention is being asked for

public enum AttentionKind: String, Codable, Sendable, CaseIterable {
    /// Claude Code asked the human a question (AskUserQuestion, MCP elicitation, agent_needs_input).
    case question
    /// A meaningful stage decision, e.g. leaving plan mode for implementation.
    case stageDecision
    /// Claude Code is blocked on a permission decision.
    case approval
    /// The turn ended on an API/runtime error (rate limit, overload, auth).
    case error
    /// The turn finished; the session is waiting for the next instruction.
    case workComplete
    /// Claude Code reported the session idle at the prompt.
    case idle
    /// The turn ended with a dedicated line asking you for something — a decision, an answer, a
    /// next step. A **request**, not a state: it survives background work, because a session can be
    /// waiting for you and still have a shell running.
    case handoff
    /// Nothing said so; we inferred it from silence. Always `.inferred`.
    case suspectedStall

    /// One order, used for two jobs.
    ///
    /// *Sorting* the queue: the most blocking ask floats to the top.
    ///
    /// *Merging within one waiting episode*: a session that already reported something specific
    /// keeps that description when a vaguer signal follows. This matters in practice — leaving
    /// plan mode fires `PreToolUse/ExitPlanMode` ("Plan ready") and then a generic
    /// `Notification/permission_prompt` a moment later; the card should still say the plan needs
    /// approving, not just "permission prompt open".
    public var rank: Int {
        switch self {
        case .question: return 100
        case .stageDecision: return 95
        case .handoff: return 92
        case .approval: return 90
        case .error: return 80
        case .workComplete: return 60
        case .idle: return 50
        case .suspectedStall: return 30
        }
    }

    public var label: String {
        switch self {
        case .approval: return "Needs approval"
        case .question: return "Asked you a question"
        case .handoff: return "Waiting for you"
        case .stageDecision: return "Stage decision"
        case .workComplete: return "Work complete"
        case .idle: return "Waiting at the prompt"
        case .error: return "Turn failed"
        case .suspectedStall: return "Suspected stall"
        }
    }

    /// The reason shown on a card when we are not carrying the hook's own message text.
    public var staticDetail: String {
        switch self {
        case .approval: return "Permission needed"
        case .question: return "Asked you a question"
        case .handoff: return "Asked you for a decision before it can carry on"
        case .stageDecision: return "Plan ready — approve to continue"
        case .workComplete: return "Turn complete — waiting for you"
        case .idle: return "Waiting at the prompt"
        case .error: return "Turn failed"
        case .suspectedStall: return "No recent activity"
        }
    }

    /// Did Claude Code actually ask for something, or is this just "the turn ended"?
    ///
    /// The generic kinds describe a *state*, not a request. They may only become something the user
    /// is shown when structured evidence positively confirms the turn finished; otherwise they stay
    /// passive. The others are real asks and are always actionable.
    public var isGeneric: Bool {
        switch self {
        case .workComplete, .idle, .suspectedStall: return true
        // A handoff is a request. It is not gated behind completion evidence, and background work
        // does not silence it: "I need a decision" and "a shell is still running" are both true.
        case .question, .stageDecision, .approval, .error, .handoff: return false
        }
    }

    /// Short glyph used in the menu bar and the alert cards.
    public var glyph: String {
        switch self {
        case .approval: return "🔐"
        case .question: return "❓"
        case .handoff: return "🙋"
        case .stageDecision: return "🚦"
        case .workComplete: return "✅"
        case .idle: return "💤"
        case .error: return "⚠️"
        case .suspectedStall: return "🐢"
        }
    }
}

/// Whether Claude Code told us, or we guessed. Never blurred in the UI.
public enum SignalSource: String, Codable, Sendable {
    /// Raised by an official Claude Code hook event.
    case explicit
    /// Derived by this app from absence of events. Lower trust.
    case inferred
}

/// Coarse class of an emitted event. Attention events carry an `attentionKind`.
public enum SignalClass: String, Codable, Sendable, CaseIterable {
    case sessionStart
    case sessionEnd
    /// Ordinary work **by the session itself**: a tool ran, a prompt was submitted. This is what
    /// says "it carried on", so it resolves a wait and supersedes a background pause.
    case activity
    /// Proof of life that is *not* the session working: a subagent finishing, for instance. It
    /// keeps the session's record current and says nothing else — in particular it must not clear
    /// a wait or make a paused session look busy. A child stopping is not the parent resuming.
    case housekeeping
    case attention
}

// MARK: - Session identity

/// Everything we keep about *where* a session lives. Deliberately minimal:
/// no prompt text, no assistant output, no transcript contents.
public struct SessionIdentity: Codable, Sendable, Equatable {
    public var sessionID: String
    public var cwd: String
    /// Claude Code process id, discovered by walking the hook process's ancestors.
    /// `nil` means we could not identify it — which is treated as "unknown", never as "alive".
    public var claudePID: Int32?
    /// Process start time (epoch seconds) so a recycled PID is not mistaken for a live session.
    public var claudePIDStartedAt: Double?
    /// Controlling terminal device of the Claude process, e.g. "/dev/ttys004".
    public var tty: String?
    /// $TERM_PROGRAM as seen by the hook ("ghostty", "iTerm.app", "Apple_Terminal", "vscode"…).
    public var termProgram: String?
    /// Apple Terminal's per-tab id.
    public var termSessionID: String?
    /// iTerm2's per-session id ("w0t0p0:UUID"). Enables exact tab targeting.
    public var itermSessionID: String?
    /// tmux pane and server socket, when running under tmux.
    public var tmuxPane: String?
    public var tmuxSocket: String?
    /// Absolute path of the terminal application bundle, when we could resolve it.
    public var terminalAppPath: String?
    /// The session's display name, from Claude Code's own registry. Never invented.
    public var title: String?
    /// Verbatim `nameSource` from the registry: how that name came to exist.
    ///
    /// It is the difference between a name somebody chose and one the client generated. On this
    /// machine the observed values are `derived` and `auto`, producing labels like `redmy-36` and
    /// `redmy-e9` — six sessions in one repository, distinguishable only by two characters. Those
    /// are identifiers, not names, and they belong in Details.
    public var titleSource: String?
    /// Branch, from the transcript tail. Stamped at session start and never revisited, so it is
    /// kept only as a fallback and is always labelled as such.
    public var gitBranch: String?
    /// The branch read from the working directory itself, with its own timestamp and outcome.
    /// Authoritative over `gitBranch` when it resolved.
    public var branch: BranchFact?

    public init(
        sessionID: String,
        cwd: String,
        claudePID: Int32? = nil,
        claudePIDStartedAt: Double? = nil,
        tty: String? = nil,
        termProgram: String? = nil,
        termSessionID: String? = nil,
        itermSessionID: String? = nil,
        tmuxPane: String? = nil,
        tmuxSocket: String? = nil,
        terminalAppPath: String? = nil,
        title: String? = nil,
        titleSource: String? = nil,
        gitBranch: String? = nil,
        branch: BranchFact? = nil
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.claudePID = claudePID
        self.claudePIDStartedAt = claudePIDStartedAt
        self.tty = tty
        self.termProgram = termProgram
        self.termSessionID = termSessionID
        self.itermSessionID = itermSessionID
        self.tmuxPane = tmuxPane
        self.tmuxSocket = tmuxSocket
        self.terminalAppPath = terminalAppPath
        self.title = title
        self.titleSource = titleSource
        self.gitBranch = gitBranch
        self.branch = branch
    }

    /// Fill in what this record does not know, from an older or less authoritative source.
    ///
    /// Only gaps. A hook that reported a worktree must never be talked out of it by a registry
    /// entry describing where the session was launched an hour ago, or by an older transcript line.
    public mutating func fillGaps(from other: SessionIdentity) {
        if cwd.isEmpty { cwd = other.cwd }
        if claudePID == nil {
            claudePID = other.claudePID
            claudePIDStartedAt = other.claudePIDStartedAt
        }
        if tty == nil { tty = other.tty }
        if title == nil {
            title = other.title
            titleSource = other.titleSource
        } else if titleSource == nil, other.title == title {
            // A name we already had, whose provenance we did not. The two are separate gaps: with
            // the old rule, a title learned from a hook could never acquire its source, so every
            // registry-generated identifier stayed indistinguishable from a name a person chose.
            // Only ever copied when it is the *same* name — a source belongs to the string it
            // describes.
            titleSource = other.titleSource
        }
        // A branch reading is about a directory. Copying one taken in a different working directory
        // would hand this session another folder's branch and call it current.
        if branch == nil, let candidate = other.branch, candidate.path == cwd { branch = candidate }
        if termProgram == nil { termProgram = other.termProgram }
        if termSessionID == nil { termSessionID = other.termSessionID }
        if itermSessionID == nil { itermSessionID = other.itermSessionID }
        if tmuxPane == nil { tmuxPane = other.tmuxPane }
        if tmuxSocket == nil { tmuxSocket = other.tmuxSocket }
        if terminalAppPath == nil { terminalAppPath = other.terminalAppPath }
        if gitBranch == nil { gitBranch = other.gitBranch }
    }

    /// Take a newer name, and its provenance, from the registry — but only for demonstrably the
    /// same session, on the same process, from a reading that is not older than what we hold.
    ///
    /// Renaming is a real thing a person does mid-session, and "fill only the gaps" meant a name
    /// could never be corrected once known. This is the narrow opposite: it touches the title and
    /// its source, and **nothing else** — never the working directory, never the branch, because
    /// the registry records where a session was launched, not where it is now.
    @discardableResult
    public mutating func refreshTitle(from scan: SessionIdentity, scannedAt: Date, holdingSince: Date) -> Bool {
        guard scan.sessionID == sessionID else { return false }
        // Same Claude process, or no claim at all. A pid that has been recycled is a different
        // session wearing the same id.
        if let mine = claudePID, let theirs = scan.claudePID {
            guard mine == theirs else { return false }
            if let myStart = claudePIDStartedAt, let theirStart = scan.claudePIDStartedAt {
                guard abs(myStart - theirStart) <= 2 else { return false }
            }
        }
        guard scannedAt >= holdingSince else { return false }        // not older than what we hold
        guard let newTitle = scan.title, !newTitle.isEmpty else { return false }
        guard let source = scan.titleSource, !source.isEmpty else { return false }
        guard newTitle != title || titleSource != source else { return false }
        title = newTitle
        titleSource = source
        return true
    }

    /// Take a fresher registry scan wholesale, for a session no hook has ever spoken for.
    ///
    /// The counterpart to `fillGaps`: with nothing authoritative to protect, a newer scan is simply
    /// the better record. A session that has moved into a worktree since it was launched should
    /// stop being labelled with the directory it started in.
    public mutating func adoptDiscovered(_ scan: SessionIdentity) {
        if !scan.cwd.isEmpty { cwd = scan.cwd }
        if scan.claudePID != nil {
            claudePID = scan.claudePID
            claudePIDStartedAt = scan.claudePIDStartedAt
        }
        if scan.tty != nil { tty = scan.tty }
        if scan.title != nil { title = scan.title; titleSource = scan.titleSource }
        if scan.gitBranch != nil { gitBranch = scan.gitBranch }
        fillGaps(from: scan)
    }

    /// The transcript tail is evidence about the past. It fills a blank; it never argues with a hook.
    public mutating func enrich(withTranscriptCwd transcriptCwd: String?, gitBranch branch: String?) {
        if cwd.isEmpty, let transcriptCwd, !transcriptCwd.isEmpty { cwd = transcriptCwd }
        if gitBranch == nil, let branch, !branch.isEmpty { gitBranch = branch }
    }

    /// Was this session's name chosen by a person, or generated by the client?
    ///
    /// Only an explicitly-set name may stand in for the folder. Anything the client derived is an
    /// identifier — it is kept, in full, in Details, but it does not get to be the label.
    static let humanNameSources: Set<String> = ["user", "custom", "explicit", "manual", "set", "named"]

    public var titleIsHumanChosen: Bool {
        guard let title, !title.isEmpty, let titleSource, !titleSource.isEmpty else { return false }
        return SessionIdentity.humanNameSources.contains(titleSource.lowercased())
    }

    /// What to call this session on screen.
    ///
    /// The worktree wins. That is what the person working in it calls it, it is what the branch is
    /// named after, and it is the thing that tells six sessions in one repository apart. A name a
    /// person actually chose beats it; a generated one does not, and goes to Details instead.
    public var displayName: String {
        if titleIsHumanChosen, let title { return title }
        return projectName
    }

    /// The branch to show, and where it came from. A reading taken from the directory now beats one
    /// stamped when the session started.
    /// The branch this session is on **now**, or nothing.
    ///
    /// Only a reading taken from the directory the session is actually in qualifies. Two things
    /// were previously allowed to stand in for it and must not: the branch stamped into the
    /// transcript at launch (observed saying `main` for five sessions each on their own `cs/…`
    /// branch), and a reading taken in a directory the session has since left. Both are kept — the
    /// first as `launchBranch`, the second discarded on merge — and neither is called current.
    /// The three readings that are statements about the directory: it is on a branch, it is on a
    /// detached HEAD, or it is not a repository. `denied`, `timedOut` and `unavailable` are failures
    /// to read, and a failure to read is not a fact about the branch.
    static let branchStatesThatAreFacts: Set<String> = ["branch", "detached", "notARepository"]

    public var branchFact: BranchFact? {
        guard let branch, branch.source == "git" else { return nil }
        guard SessionIdentity.branchStatesThatAreFacts.contains(branch.state) else { return nil }
        guard branch.path == cwd else { return nil }      // read somewhere this session no longer is
        return branch
    }

    /// The branch stamped when the session started. Kept, and labelled as what it is.
    ///
    /// Useful in Details and for compatibility; never an answer to "which branch is it on now".
    public var launchBranch: BranchFact? {
        guard let gitBranch, !gitBranch.isEmpty else { return nil }
        return BranchFact.transcript(gitBranch, path: cwd, at: .distantPast)
    }

    /// Why there is no current branch yet, in one word: `read` (there is one), `pending` (nothing has
    /// been read for this directory yet), or the reading's own failure state.
    public var branchAvailability: String {
        if branchFact != nil { return "read" }
        guard let branch else { return "pending" }
        if branch.path != cwd { return "pending" }        // the reading belongs to another directory
        return branch.source == "git" ? branch.state : "pending"
    }

    /// The generated label, kept for Details. Nil when the name is one a person chose — that one is
    /// already on screen.
    public var generatedLabel: String? {
        guard let title, !title.isEmpty, !titleIsHumanChosen else { return nil }
        return title
    }

    /// Human label: the project folder name.
    public var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }

    public var shortSessionID: String {
        String(sessionID.prefix(8))
    }

    /// Terminal name suitable for display.
    public var terminalName: String {
        if let path = terminalAppPath, let range = path.range(of: ".app", options: .backwards) {
            let bundle = String(path[path.startIndex..<range.lowerBound])
            return (bundle as NSString).lastPathComponent
        }
        switch termProgram?.lowercased() {
        case "iterm.app": return "iTerm2"
        case "apple_terminal": return "Terminal"
        case "ghostty": return "Ghostty"
        case "vscode": return "VS Code"
        case .some(let other) where !other.isEmpty: return other
        default: return "terminal"
        }
    }
}

// MARK: - Wire format between the hook emitter and the app

/// One record written by `aa-emit` into the spool directory.
/// `schema` lets a future emitter/app pair disagree safely.
public struct EmittedEvent: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var id: String
    public var hookEvent: String
    public var signal: SignalClass
    public var attentionKind: AttentionKind?
    public var source: SignalSource
    /// Short human reason, e.g. "Permission needed: Bash". Truncated by the emitter.
    public var detail: String?
    public var occurredAt: Date
    public var identity: SessionIdentity
    /// Only ever set on a `Stop` event: what the turn left running behind it.
    public var background: BackgroundEvidence?
    /// The turn handed something back for the **user** to try, test or review. Read from the final
    /// message's own handoff footer; never inferred from prose, and never from a background job.
    public var awaitsUserAcceptance: Bool

    public init(
        schema: Int = EmittedEvent.currentSchema,
        id: String = UUID().uuidString,
        hookEvent: String,
        signal: SignalClass,
        attentionKind: AttentionKind? = nil,
        source: SignalSource = .explicit,
        detail: String? = nil,
        occurredAt: Date,
        identity: SessionIdentity,
        background: BackgroundEvidence? = nil,
        awaitsUserAcceptance: Bool = false
    ) {
        self.schema = schema
        self.id = id
        self.hookEvent = hookEvent
        self.signal = signal
        self.attentionKind = attentionKind
        self.source = source
        self.detail = detail
        self.occurredAt = occurredAt
        self.identity = identity
        self.background = background
        self.awaitsUserAcceptance = awaitsUserAcceptance
    }

    public var sessionID: String { identity.sessionID }
}

// MARK: - Queue item

public struct AttentionItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sessionID: String
    /// The waiting episode this item belongs to. A session opens a new episode only when it does
    /// real work again, so every signal arriving while it waits lands on the same item.
    public var episodeID: String
    public var kind: AttentionKind
    public var source: SignalSource
    public var detail: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var occurrences: Int
    public var snoozedUntil: Date?
    public var identity: SessionIdentity
    /// This item is an **acceptance checkpoint**: the session handed something back for the user to
    /// try, test or review.
    ///
    /// It changes one thing, and it is the important one: the session going back to work does not
    /// close it. A shell finishing, a monitor ticking, the agent carrying on by itself — none of
    /// that is the user having looked at the work, and treating it as such is how a handoff gets
    /// walked past. Only the user responding, or dismissing it, closes one.
    public var awaitsUserAcceptance: Bool
    /// When the user last had this item **in front of them** — the moment the panel was open with
    /// this row in it.
    ///
    /// Separate from every other date here, and separate from dismissal, because "I have seen this"
    /// and "I am done with this" are different facts and were being counted as one. A handoff that
    /// deliberately waits until it is answered is not new after the first look, and a badge that
    /// keeps insisting it is trains people to stop reading it. `nil` means never looked at.
    public var seenAt: Date?
    /// When the user actually **went to this session's tab** from this row.
    ///
    /// A third distinct fact, and the reason it is not folded into either of the others: *read* is
    /// not *visited* is not *dealt with*. Arriving at a tab used to remove the row outright, on the
    /// grounds that landing there meant it was handled — but opening a session to look at it is
    /// routinely how you find out it still needs you. So a visit demotes rather than deletes: the
    /// row drops below everything you have not been to yet, and stays until it is answered or
    /// dismissed. `nil` means never opened from here.
    public var visitedAt: Date?

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        episodeID: String,
        kind: AttentionKind,
        source: SignalSource,
        detail: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        occurrences: Int = 1,
        snoozedUntil: Date? = nil,
        identity: SessionIdentity,
        awaitsUserAcceptance: Bool = false,
        seenAt: Date? = nil,
        visitedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.episodeID = episodeID
        self.kind = kind
        self.source = source
        self.detail = detail
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.occurrences = occurrences
        self.snoozedUntil = snoozedUntil
        self.identity = identity
        self.awaitsUserAcceptance = awaitsUserAcceptance
        self.seenAt = seenAt
        self.visitedAt = visitedAt
    }

    /// Not looked at yet. What the bubble's badge counts.
    public var isUnseen: Bool { seenAt == nil }
    /// Not been opened from here yet. What decides where the row sits.
    public var isUnvisited: Bool { visitedAt == nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        episodeID = try c.decode(String.self, forKey: .episodeID)
        kind = try c.decode(AttentionKind.self, forKey: .kind)
        source = try c.decode(SignalSource.self, forKey: .source)
        detail = try c.decode(String.self, forKey: .detail)
        firstSeenAt = try c.decode(Date.self, forKey: .firstSeenAt)
        lastSeenAt = try c.decode(Date.self, forKey: .lastSeenAt)
        occurrences = ((try? c.decodeIfPresent(Int.self, forKey: .occurrences)) ?? nil) ?? 1
        snoozedUntil = (try? c.decodeIfPresent(Date.self, forKey: .snoozedUntil)) ?? nil
        identity = try c.decode(SessionIdentity.self, forKey: .identity)
        // An item saved before acceptance checkpoints existed is an ordinary wait.
        awaitsUserAcceptance =
            ((try? c.decodeIfPresent(Bool.self, forKey: .awaitsUserAcceptance)) ?? nil) ?? false
    }

    public func isVisible(at now: Date) -> Bool {
        guard let until = snoozedUntil else { return true }
        return until <= now
    }

    public var isSuspected: Bool { source == .inferred }

    /// One-line reason shown on the card.
    public var reasonLine: String {
        let prefix = isSuspected ? "Suspected — " : ""
        return detail.isEmpty ? prefix + kind.label : prefix + detail
    }
}

// MARK: - Session bookkeeping

public enum SessionActivityState: String, Codable, Sendable {
    /// Ran a tool or received a prompt recently. The only state a stall can be inferred from.
    case working
    /// Has an open ask, or had one dismissed, and has done nothing since.
    case awaitingUser
    case ended
    /// Registered but never seen working — a freshly opened client sitting at its prompt.
    /// Not evidence of anything, so nothing is inferred from it.
    case unknown
    /// Found in Claude Code's session registry, but no hook has ever reported for it. We know it
    /// exists and nothing else — in particular, not whether it wants anything.
    case discovered
    /// The turn ended, but the session told us work is still running behind it. Not finished, and
    /// not asking for anything: waiting.
    case backgroundWaiting

    /// A value written by a newer version reads as `unknown` rather than failing to load.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionActivityState(rawValue: raw) ?? .unknown
    }
}

/// What a registry scan knew about a session, kept separately from anything a hook said.
public struct SessionDiscovery: Codable, Sendable, Equatable {
    public var discoveredAt: Date
    public var registryUpdatedAt: Date?
    /// Verbatim from the registry, and never interpreted as attention or activity.
    public var registryStatus: String?
    public var version: String?

    public init(discoveredAt: Date, registryUpdatedAt: Date? = nil, registryStatus: String? = nil, version: String? = nil) {
        self.discoveredAt = discoveredAt
        self.registryUpdatedAt = registryUpdatedAt
        self.registryStatus = registryStatus
        self.version = version
    }
}

public struct SessionState: Codable, Sendable, Equatable {
    public var identity: SessionIdentity
    public var activity: SessionActivityState
    /// Last time *any* event arrived for this session.
    public var lastEventAt: Date
    /// Last time ordinary work happened (prompt submitted, tool ran).
    public var lastActivityAt: Date
    /// Identifies the current waiting episode; regenerated whenever work resumes.
    public var episodeID: String
    public var currentItemID: String?
    /// The user dismissed this episode. Further signals for it stay quiet until work resumes.
    public var episodeDismissed: Bool
    /// Has a real Claude Code hook ever reported for this session?
    ///
    /// False means everything we know came from the registry: the session exists, and its attention
    /// state is genuinely unknown. It is the difference between "nothing is waiting" and
    /// "we have not heard".
    public var hasHookEvidence: Bool
    /// Set when the session was found by a registry scan.
    public var discovery: SessionDiscovery?
    /// The most recent `Stop` reading of what is running behind the turn.
    public var background: BackgroundEvidence?
    /// When real work happened after that reading was taken.
    ///
    /// The reading itself is kept — it is still the best description of what the session left
    /// running — but it can no longer *confirm* anything, because it describes a turn that has
    /// since been superseded. Without this, a bare `agent_completed` arriving after the session
    /// went back to work would reuse the old confirmed `Stop` and manufacture a completion.
    public var backgroundSupersededAt: Date?
    /// Every background job this session is known to have, kept **apart** from what the turn is
    /// doing and from what it is asking for.
    ///
    /// Three separate questions, three separate fields. Folding them together is how a running
    /// monitor comes to look like an unanswered question, and how a shell finishing comes to look
    /// like a goal being met. The registry never claims to be the whole list.
    public var jobs: BackgroundRegistry

    public init(
        identity: SessionIdentity,
        activity: SessionActivityState,
        lastEventAt: Date,
        lastActivityAt: Date,
        episodeID: String = UUID().uuidString,
        currentItemID: String? = nil,
        episodeDismissed: Bool = false,
        hasHookEvidence: Bool = true,
        discovery: SessionDiscovery? = nil,
        background: BackgroundEvidence? = nil,
        backgroundSupersededAt: Date? = nil,
        jobs: BackgroundRegistry = BackgroundRegistry()
    ) {
        self.identity = identity
        self.activity = activity
        self.lastEventAt = lastEventAt
        self.lastActivityAt = lastActivityAt
        self.episodeID = episodeID
        self.currentItemID = currentItemID
        self.episodeDismissed = episodeDismissed
        self.hasHookEvidence = hasHookEvidence
        self.discovery = discovery
        self.background = background
        self.backgroundSupersededAt = backgroundSupersededAt
        self.jobs = jobs
    }

    /// A state file written before discovery existed has no `hasHookEvidence` — and everything in
    /// it came from hooks, so that is what it defaults to.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(SessionIdentity.self, forKey: .identity)
        activity = (try? c.decode(SessionActivityState.self, forKey: .activity)) ?? .unknown
        lastEventAt = try c.decode(Date.self, forKey: .lastEventAt)
        lastActivityAt = try c.decode(Date.self, forKey: .lastActivityAt)
        episodeID = (try? c.decodeIfPresent(String.self, forKey: .episodeID)) as? String ?? UUID().uuidString
        currentItemID = try? c.decodeIfPresent(String.self, forKey: .currentItemID)
        episodeDismissed = ((try? c.decodeIfPresent(Bool.self, forKey: .episodeDismissed)) ?? nil) ?? false
        // `stallRaisedForActivityAt` was written by builds up to 0.4. Inferred inactivity is gone,
        // so the key is simply ignored — an old state file still loads.
        hasHookEvidence = ((try? c.decodeIfPresent(Bool.self, forKey: .hasHookEvidence)) ?? nil) ?? true
        discovery = try? c.decodeIfPresent(SessionDiscovery.self, forKey: .discovery)
        background = try? c.decodeIfPresent(BackgroundEvidence.self, forKey: .background)
        backgroundSupersededAt = try? c.decodeIfPresent(Date.self, forKey: .backgroundSupersededAt)
        // A saved state written before the registry existed decodes to an empty one whose coverage
        // is `unknown` — never to "this session has no background jobs".
        jobs = ((try? c.decodeIfPresent(BackgroundRegistry.self, forKey: .jobs)) ?? nil)
            ?? BackgroundRegistry()
    }

    /// True when nothing but a registry scan has ever mentioned this session.
    public var isDiscoveredOnly: Bool { !hasHookEvidence }

    /// Waiting on something it started, rather than on you — **right now**.
    ///
    /// Deliberately scoped to the session's current state as well as the evidence. A `Stop` that
    /// reported a running task is a fact about a moment; once the session does real work again, or
    /// asks you something, it is no longer paused, and a retained task snapshot must not keep
    /// saying otherwise. That is the difference between "what we last read" and "what is true now".
    public func isWaitingOnBackgroundWork(at now: Date, ttl: TimeInterval) -> Bool {
        guard activity == .backgroundWaiting else { return false }
        guard let background, background.isWaitingOnBackgroundWork else { return false }
        return !background.isStale(at: now, after: ttl)
    }

    /// How sure are we that this session's last turn finished?
    ///
    /// Evidence that is absent, unreadable or older than the TTL is `uncertain`, never `confirmed`.
    /// This is the gate a generic "turn ended" signal has to pass before it can become an alert.
    public func completionCertainty(at now: Date, ttl: TimeInterval) -> CompletionCertainty {
        guard let background, !background.isStale(at: now, after: ttl) else { return .uncertain }
        // Work happened after this reading was taken, so it describes a turn that is over. It stays
        // on the record as a description; it stops being a confirmation.
        if let superseded = backgroundSupersededAt, background.observedAt <= superseded { return .uncertain }
        if background.hasFailure { return .uncertain }
        if background.isWaitingOnBackgroundWork { return .paused }
        if background.isConfirmedComplete { return .confirmed }
        return .uncertain
    }

    /// What can be said about this session needing you **now**.
    ///
    /// One definition, used by both the status report and the panel, because two copies of this rule
    /// would eventually disagree and the app would say one thing on screen and another on the
    /// command line about the same session.
    public func attentionCertainty(at now: Date, ttl: TimeInterval) -> SessionAttentionCertainty {
        if currentItemID != nil { return .waiting }
        if isDiscoveredOnly { return .awaitingFirstHook }
        switch activity {
        case .backgroundWaiting:
            // Only while the reading is still current. A pause recorded an hour ago is not a
            // statement about now.
            return isWaitingOnBackgroundWork(at: now, ttl: ttl) ? .none : .uncertain
        case .working, .awaitingUser:
            return .none
        case .unknown, .ended, .discovered:
            // The turn ended and nothing confirmed how, or the evidence has aged out. Calling this
            // "quiet" is the mistake the whole completion-certainty rule exists to stop.
            return .uncertain
        }
    }
}

/// The four things that can be said about a session's need for you. `none` means "nothing is being
/// asked", never "nothing is wrong".
public enum SessionAttentionCertainty: String, Sendable, Equatable {
    case waiting
    case awaitingFirstHook
    case none
    case uncertain
}

// MARK: - What the engine asks the UI to do

public enum EngineEffect: Sendable, Equatable {
    /// A brand new item entered the queue: show it, optionally speak it.
    case raised(AttentionItem)
    /// An existing item was seen again or refined: update it, stay quiet.
    case repeated(AttentionItem)
    /// A previously snoozed item became visible again.
    case unsnoozed(AttentionItem)
    /// The item left the queue.
    case resolved(itemID: String, reason: ResolutionReason)
    /// A session record was dropped.
    case sessionDropped(sessionID: String, reason: DropReason)

    /// The item this effect concerns, when it has one.
    public var itemID: String? {
        switch self {
        case .raised(let item), .repeated(let item), .unsnoozed(let item): return item.id
        case .resolved(let id, _): return id
        case .sessionDropped: return nil
        }
    }

    public enum ResolutionReason: String, Sendable {
        case sessionResumedWork
        case dismissed
        case sessionEnded
        case processGone
        case expired
        /// Newer evidence contradicts what the card claimed — a "turn complete" followed by a
        /// `Stop` reporting work still running. Only ever applied to generic items; a real ask is
        /// never withdrawn on the app's own initiative.
        case evidenceWithdrawn
    }

    public enum DropReason: String, Sendable {
        case sessionEnded
        case processGone
        case stale
    }
}

// MARK: - Making a folder name readable

/// Turns a worktree folder into something a person reads at a glance.
///
/// Strictly typographic. It splits on the delimiters that are already there, sentence-cases the
/// words, and uppercases a token that is *already* a ticket identifier. It never adds a word, never
/// expands an abbreviation, and never consults content — `red658-plan-vs-ledger` becomes
/// `RED-658 · Plan vs ledger` because every part of that was in the folder name.
///
/// A name a person chose is never touched by any of this.
public enum SessionNameStyle {
    /// `red658` → `RED-658`. Letters then digits, nothing else, and short enough to be an id.
    static func ticketID(_ token: String) -> String? {
        guard token.count >= 4, token.count <= 12 else { return nil }
        let letters = token.prefix { $0.isLetter }
        let digits = token.dropFirst(letters.count)
        guard letters.count >= 2, letters.count <= 6, digits.count >= 2, digits.count <= 6,
              digits.allSatisfy(\.isNumber) else { return nil }
        return "\(letters.uppercased())-\(digits)"
    }

    /// `t1` → `T1`. A single letter and a small number, the way people label a variant.
    static func variantTag(_ token: String) -> String? {
        guard token.count >= 2, token.count <= 3 else { return nil }
        let letter = token.prefix(1)
        let digits = token.dropFirst()
        guard letter.allSatisfy(\.isLetter), digits.allSatisfy(\.isNumber) else { return nil }
        return token.uppercased()
    }

    public static func humanised(_ raw: String) -> String {
        let tokens = raw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).map(String.init)
        guard !tokens.isEmpty else { return raw }
        guard tokens.count > 1 else { return tokens[0].prefix(1).uppercased() + tokens[0].dropFirst() }

        var head: String?
        var tail: String?
        var body = tokens

        if let ticket = ticketID(body[0]) {
            head = ticket
            body.removeFirst()
        }
        if body.count > 1, let variant = variantTag(body[body.count - 1]) {
            tail = variant
            body.removeLast()
        }
        guard !body.isEmpty else { return [head, tail].compactMap { $0 }.joined(separator: " · ") }

        let sentence = body.joined(separator: " ")
        let cased = sentence.prefix(1).uppercased() + sentence.dropFirst()
        return [head, cased, tail].compactMap { $0 }.joined(separator: " · ")
    }
}

extension SessionIdentity {
    /// What the row shows: a chosen name verbatim, or the worktree made readable.
    public var readableName: String {
        if titleIsHumanChosen, let title { return title }
        return SessionNameStyle.humanised(projectName)
    }
}
