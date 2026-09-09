import Foundation
import CryptoKit

/// Starts a Claude Code client and talks to it. A seam, so every rule below can be tested without
/// launching anything.
public protocol BridgeClientLaunching: Sendable {
    /// Launch a client for `session`, writing each line it produces to `onLine`, and calling
    /// `onExit` once when it goes. Returns a handle for writing to it.
    func launch(sessionID: String,
                cwd: String,
                model: String?,
                onLine: @escaping (String) -> Void,
                onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle
}

/// A running client this host owns.
public protocol BridgeClientHandle: Sendable {
    var pid: Int32 { get }
    /// Is the process still up? Asked of the process itself, never inferred from our own intent.
    ///
    /// Defaulted, so a stand-in in a test does not have to model process liveness to be useful —
    /// but the real handle answers from the process, which is what shutdown depends on.
    var isRunning: Bool { get }
    /// Write one line of stream-json input. Returns false when the pipe is gone.
    @discardableResult func write(line: String) -> Bool
    /// Stop **this** process. Nothing else is ever signalled.
    func terminate()
}

public extension BridgeClientHandle {
    var isRunning: Bool { true }
}

/// The Warden-owned bridge: sessions it started, and nothing else.
///
/// **What this is.** A way for an authorised local caller to start a *new* official Claude Code
/// session in an approved directory, send it a prompt, send a follow-up to the same session, and be
/// told — separately — that the request was accepted, that the client actually acknowledged it, that
/// work is happening, what came out, and whether the turn finished, failed, or cannot be called
/// either.
///
/// **What this is not, and cannot be made into by asking nicely.** It does not attach to a session
/// somebody already has open in a terminal. A session id it did not create is refused, always:
/// adopting one would mean two things driving the same conversation, and the person at the keyboard
/// would not know. Nor does it type into anything: the client is started as a child process with
/// streaming input, which is the interface Claude Code documents for exactly this.
///
/// **Ambiguity is reported, never resolved by guessing.** If the client disconnects or a deadline
/// passes with no result, the turn is `uncertain` and stays that way. Nothing is resent
/// automatically — a retry that a caller did not ask for is how one instruction becomes two.
public final class BridgeHost: @unchecked Sendable {
    private let launcher: BridgeClientLaunching
    private let now: () -> Date
    /// Directories a session may be started in. Empty means "none", not "any".
    private let approvedRoots: [String]
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var startRequests: [String: (fingerprint: String, sessionID: String)] = [:]

    /// The launcher for visible sessions, when this host was given one. Absent means visible
    /// sessions are simply not offered — never quietly downgraded to a background client, which
    /// would give a caller a session it cannot see while telling it everything went fine.
    private let visibleLauncher: BridgeClientLaunching?

    public init(launcher: BridgeClientLaunching,
                approvedRoots: [String],
                visibleLauncher: BridgeClientLaunching? = nil,
                now: @escaping () -> Date = Date.init) {
        self.visibleLauncher = visibleLauncher
        self.launcher = launcher
        self.approvedRoots = approvedRoots.map { BridgeHost.normalise($0) }
        self.now = now
    }

    // MARK: - One owned session

    private final class Session {
        var state: BridgeSessionState
        var handle: BridgeClientHandle?
        var events: [BridgeEvent] = []
        var droppedEvents = 0
        /// messageID → what was sent under it. Written **before** the write is attempted, so an
        /// ambiguous failure can never be retried as though nothing happened.
        var sentPrompts: [String: String] = [:]
        /// The one turn this session owns until it is genuinely resolved.
        ///
        /// A deadline passing, or a write failing, makes it **uncertain** — it does *not* release
        /// it. Releasing on a timeout is how a later turn inherits an earlier turn's result: the
        /// old client answers, the old turn is gone, and the answer lands on whatever came next.
        /// Only a result attributed to this turn, the client's exit, or a stop lets go of it.
        var inFlight: InFlight?

        struct InFlight {
            let messageID: String
            let correlationID: String
            /// The client uuid written on the frame we sent. The documented join key.
            let clientUUID: String
            /// Set once the client has stamped this uuid on a reply, which proves the producer
            /// supports the join key at all. Until then, correlation falls back to the exact echo
            /// and the turn is treated as ambiguous if anything autonomous happens meanwhile.
            var joinKeyConfirmed = false
            /// The exact text this host wrote, correlation footer included. The echo has to match
            /// it, or it is not an acknowledgement of this.
            let sentBody: String
            var unresolved = false
        }
        /// Correlation ids already acknowledged, so a repeated echo cannot acknowledge twice.
        var acknowledgedCorrelations: Set<String> = []
        /// Identities of results that have already settled a turn here, oldest first and bounded.
        /// A client that repeats an answer — a replayed frame, a reconnect, a resent buffer — must
        /// not be able to settle a *different* turn with it.
        var settledResults: [String] = []
        var settledResultIdentities: Set<String> = []
        /// When this session last did something that belongs to the turn in flight. Used to anchor
        /// that turn's deadline, so an unrelated frame cannot postpone a real timeout for ever.
        var lastRelevantActivityAt: Date?
        var launching = false
        var stopRequested = false
        /// Background jobs this session has told us about. A third account, kept apart from the
        /// turn's phase and from the messages: a task finishing is not a turn finishing.
        var jobs = BackgroundRegistry()
        /// When the session last did work nobody asked it for. Recorded, and never used to settle
        /// a submitted turn.
        var autonomousActivityAt: Date?
        /// This client has stamped a join key at least once, so it supports them. After that, a
        /// result arriving without one is a statement rather than a limitation.
        var joinKeysSeen = false
        /// What the client last said its session state was: `working`, `idle`, `requiresAction`.
        /// Only ever what it said — never inferred from silence or from a job.
        var parentState = "unknown"
        var parentStateAt: Date?
        /// An open ask this session has put to the user.
        var attention: BridgeAttentionState?

        init(state: BridgeSessionState) { self.state = state }
    }

    // MARK: - Requests

    public func handle(_ request: BridgeRequest) -> BridgeResponse {
        switch request {
        case .start(let start): return handleStart(start)
        case .send(let send): return handleSend(send)
        case .status(let sessionID): return handleStatus(sessionID)
        case .events(let sessionID, let after): return handleEvents(sessionID, after: after)
        case .stop(let sessionID): return handleStop(sessionID)
        case .focus(let sessionID): return focus(sessionID: sessionID)
        }
    }

    private func handleStart(_ request: BridgeRequest.StartRequest) -> BridgeResponse {
        guard BridgeHost.isUsableIdentifier(request.requestID) else {
            return refusal(.malformed, "A request id must be 1…\(BridgeProtocol.maximumIdentifierLength) printable characters.")
        }
        // The directory is resolved through its symlinks before it is compared, so an approved root
        // cannot be reached — or escaped — by a link pointing somewhere else.
        guard let cwd = BridgeHost.resolve(request.cwd) else {
            return refusal(.directoryNotApproved,
                           "\(request.cwd) is not a directory this host can resolve.")
        }

        lock.lock()
        if let previous = startRequests[request.requestID] {
            defer { lock.unlock() }
            // A retry must be the *same* request. Reusing an id with a different directory or model
            // is a different intention wearing an old name.
            guard previous.fingerprint == request.intentFingerprint else {
                return refusal(.idempotencyConflict,
                               "Request id \(request.requestID) was already used for a different "
                               + "directory or model.")
            }
            guard let session = sessions[previous.sessionID] else {
                return refusal(.clientUnavailable, "That session is no longer held by this host.")
            }
            return BridgeResponse(ok: true, session: session.state)
        }
        guard sessions.count < BridgeProtocol.maximumSessions else {
            defer { lock.unlock() }
            return refusal(.limitReached,
                           "This host already owns \(sessions.count) sessions, which is its limit.")
        }
        guard startRequests.count < BridgeProtocol.maximumStartRequests else {
            defer { lock.unlock() }
            return refusal(.limitReached, "This host is remembering as many start requests as it will.")
        }
        guard isApproved(cwd) else {
            defer { lock.unlock() }
            return refusal(.directoryNotApproved,
                           "A session may only be started inside an approved directory. "
                           + "\(request.cwd) is not one of them.")
        }

        // **Generated, never accepted from a caller.** A caller-supplied id could name a session
        // somebody already has open, and this host must not be able to touch one of those even by
        // accident.
        let sessionID = UUID().uuidString
        let session = Session(state: BridgeSessionState(
            sessionID: sessionID, cwd: cwd, phase: .accepted, startedAt: now()))
        session.launching = true
        sessions[sessionID] = session
        startRequests[request.requestID] = (request.intentFingerprint, sessionID)
        lock.unlock()

        // Which surface? The default is unchanged — the background client with pipes. A caller
        // that asks for a terminal gets one or gets a refusal; it never gets a background session
        // it believes it can see.
        var chosen = launcher
        if let terminal = request.terminal?.lowercased(), !terminal.isEmpty {
            guard terminal == "ghostty" else {
                lock.lock()
                session.launching = false
                session.state.phase = .failed
                append(.error, to: session, text: "unsupported terminal \(terminal)")
                let snapshot = session.state
                lock.unlock()
                return BridgeResponse(ok: false,
                                      error: BridgeError(code: .malformed,
                                                         message: "\(terminal) is not a terminal "
                                                                + "this host can open. Supported: ghostty."),
                                      session: snapshot)
            }
            guard let visible = visibleLauncher else {
                lock.lock()
                session.launching = false
                session.state.phase = .failed
                append(.error, to: session, text: "visible sessions are not available on this host")
                let snapshot = session.state
                lock.unlock()
                return BridgeResponse(ok: false,
                                      error: BridgeError(code: .clientUnavailable,
                                                         message: "This host cannot open visible "
                                                                + "sessions. Run it on macOS with "
                                                                + "Ghostty installed."),
                                      session: snapshot)
            }
            chosen = visible
        }

        // Launched outside the lock: starting a process can block, and a status request must not
        // wait behind it.
        do {
            let handle = try chosen.launch(
                sessionID: sessionID, cwd: cwd, model: request.model,
                onLine: { [weak self] line in self?.receive(line, for: sessionID) },
                onExit: { [weak self] status in self?.clientExited(sessionID, status: status) })

            lock.lock()
            session.launching = false
            // The client can be gone before `launch` even returns — a executable that exits at once
            // calls back synchronously. Installing the handle now would mean holding a live client
            // for a process whose exit is already recorded, and `hasRunningClients` would then keep
            // a dead session alive for ever.
            if let status = session.state.exitStatus {
                session.state.pid = handle.pid
                append(.note, to: session,
                       text: "the client exited with status \(status) before it could be attached; "
                           + "no handle is held for a process that has already gone")
                let snapshot = session.state
                lock.unlock()
                return BridgeResponse(ok: false,
                                      error: BridgeError(code: .clientUnavailable,
                                                         message: "The client exited immediately "
                                                                + "(status \(status))."),
                                      session: snapshot)
            }
            // A stop that arrived while the launcher was working still wins: otherwise the process
            // it could not see yet would be left running. The handle is **kept** so its exit can be
            // observed — the stop is asked for here, not confirmed.
            if session.stopRequested {
                session.handle = handle
                session.state.pid = handle.pid
                session.state.phase = .stopping
                append(.note, to: session, text: "stopped while the client was starting")
                let snapshot = session.state
                lock.unlock()
                handle.terminate()
                return BridgeResponse(ok: true, session: snapshot)
            }
            session.handle = handle
            session.state.pid = handle.pid
            if let visible = handle as? VisibleClaudeHandle {
                session.state.surface = BridgeSurfaceState(terminal: "ghostty",
                                                           windowID: visible.surface.windowID,
                                                           tabID: visible.surface.tabID,
                                                           terminalID: visible.surface.terminalID,
                                                           open: true)
                append(.started, to: session,
                       text: "session opened in a Ghostty tab (terminal \(visible.surface.terminalID))")
            } else {
                append(.started, to: session, text: "client started, pid \(handle.pid)")
            }
            let snapshot = session.state
            lock.unlock()
            return BridgeResponse(ok: true, session: snapshot)
        } catch {
            lock.lock()
            session.launching = false
            session.state.phase = .failed
            append(.error, to: session, text: "could not start a client: \(error.localizedDescription)")
            let snapshot = session.state
            lock.unlock()
            return BridgeResponse(ok: false,
                                  error: BridgeError(code: .clientUnavailable,
                                                     message: "Could not start a Claude Code client: "
                                                            + error.localizedDescription),
                                  session: snapshot)
        }
    }

    private func handleSend(_ request: BridgeRequest.SendRequest) -> BridgeResponse {
        guard BridgeHost.isUsableIdentifier(request.messageID) else {
            return refusal(.malformed, "A message id must be 1…\(BridgeProtocol.maximumIdentifierLength) printable characters.")
        }
        guard request.prompt.utf8.count <= BridgeProtocol.maximumPromptBytes else {
            return refusal(.limitReached, "That prompt is larger than this host will send.")
        }

        lock.lock()
        guard let session = sessions[request.sessionID] else {
            defer { lock.unlock() }
            return refusal(.notOwned,
                           "This host did not start session \(request.sessionID), so it will not "
                           + "send to it. Sessions opened in a terminal are observed, never driven.")
        }
        guard !session.stopRequested, session.state.exitStatus == nil else {
            defer { lock.unlock() }
            return refusal(.clientUnavailable, session.stopRequested
                ? "That session was stopped; nothing more will be sent to it."
                : "That session's client has already gone.")
        }

        let fingerprint = BridgeHost.fingerprint(request.prompt)
        if let previous = session.sentPrompts[request.messageID] {
            defer { lock.unlock() }
            guard previous == fingerprint else {
                return refusal(.idempotencyConflict,
                               "Message id \(request.messageID) was already used for different text.")
            }
            // Already sent — or attempted. Either way it is not sent again: a retry after an
            // ambiguous write is exactly how one instruction becomes two.
            return BridgeResponse(ok: true, session: session.state)
        }
        // One turn at a time — including a turn that has gone quiet. An unresolved turn still owns
        // this session: its client may yet answer, and that answer must not be able to land on
        // something sent afterwards.
        if let inFlight = session.inFlight {
            defer { lock.unlock() }
            return refusal(.busy, inFlight.unresolved
                ? "Message \(inFlight.messageID) is unresolved — the client may still answer it. "
                + "Stop the session if you want to abandon it; nothing new will be sent meanwhile."
                : "This session is still working on message \(inFlight.messageID). "
                + "Wait for its result before sending another.")
        }
        guard session.state.messages.count < BridgeProtocol.maximumMessagesPerSession else {
            defer { lock.unlock() }
            return refusal(.limitReached, "This session is remembering as many messages as it will.")
        }
        guard let handle = session.handle else {
            defer { lock.unlock() }
            return refusal(.clientUnavailable, "That session has no running client.")
        }

        // The intent is recorded *before* the write, so a write that fails halfway is still
        // remembered and cannot be replayed.
        // The caller sending the next prompt *is* the response an acceptance checkpoint was
        // waiting for. Nothing else closes one: not a task finishing, not the session working on
        // its own, not the turn completing.
        session.attention = nil
        let correlationID = UUID().uuidString
        let clientUUID = UUID().uuidString
        let body = BridgeHost.messageBody(text: request.prompt, correlationID: correlationID)
        session.sentPrompts[request.messageID] = fingerprint
        session.inFlight = Session.InFlight(messageID: request.messageID,
                                            correlationID: correlationID,
                                            clientUUID: clientUUID, sentBody: body)
        session.state.messages.append(BridgeMessageState(
            messageID: request.messageID, phase: .accepted, sentAt: now(),
            promptFingerprint: fingerprint, correlationID: correlationID))
        // Set **before** the write. A client can answer inside the write call itself, and a phase
        // assigned afterwards would overwrite a real completion with "accepted".
        session.state.phase = .accepted
        let frame = BridgeHost.frame(body: body, sessionID: request.sessionID,
                                     clientUUID: clientUUID)
        lock.unlock()

        // Written outside the lock: a blocked pipe must not freeze every other request.
        let written = handle.write(line: frame)

        lock.lock()
        defer { lock.unlock() }
        guard written else {
            session.state.phase = .uncertain
            if let index = session.state.messages.lastIndex(where: { $0.messageID == request.messageID }) {
                session.state.messages[index].phase = .uncertain
            }
            // Kept, not cleared: a partial write may still have arrived, so this turn keeps owning
            // the session until something real settles it.
            session.inFlight?.unresolved = true
            append(.error, to: session,
                   text: "the client's input pipe would not take message \(request.messageID); "
                       + "whether any of it arrived is unknown, and it will not be sent again",
                   messageID: request.messageID)
            return BridgeResponse(ok: false,
                                  error: BridgeError(code: .clientUnavailable,
                                                     message: "The client did not accept the prompt. "
                                                            + "Delivery is uncertain and nothing was resent."),
                                  session: session.state)
        }
        // Nothing is written back to `phase` here. If the client already answered during the write,
        // that answer stands.
        return BridgeResponse(ok: true, session: session.state)
    }

    /// The wire view of a session: its own state plus the job registry and autonomous marker,
    /// which live beside the phase rather than inside it.
    private func published(_ session: Session) -> BridgeSessionState {
        let moment = now()
        // A client that has gone cannot have anything running *now*. Its rows are history, and are
        // marked stale whatever their age — the alternative is a dead session showing live work.
        let alive = session.state.exitStatus == nil
            && (session.handle?.isRunning ?? session.launching)
        var state = session.state
        state.jobs = session.jobs.jobs.map { job in
            let age = moment.timeIntervalSince(job.observedAt)
            return BridgeJobState(
                sessionID: job.identity.sessionID, taskID: job.identity.taskID,
                namespace: job.identity.namespace.rawValue,
                kind: job.kind.rawValue, state: job.state.rawValue, source: job.source.rawValue,
                type: job.typeLabel, toolUseID: job.toolUseID, recurring: job.recurring,
                ambient: job.ambient, observedAt: job.observedAt,
                ageSeconds: (age * 10).rounded() / 10,
                stale: !alive || age > BridgeHost.freshnessWindow)
        }
        state.jobCoverage = session.jobs.coverage.rawValue
        state.jobsOmitted = session.jobs.evicted
        state.autonomousActivityAt = session.autonomousActivityAt

        // What the *session* is doing, which is not what happened to our last message.
        let reported = session.parentState
        let parentAge = session.parentStateAt.map { moment.timeIntervalSince($0) }
        state.parent = BridgeParentActivity(
            state: alive ? reported : "unknown",
            observedAt: session.parentStateAt,
            ageSeconds: parentAge.map { ($0 * 10).rounded() / 10 },
            stale: !alive || (parentAge ?? .infinity) > BridgeHost.freshnessWindow,
            autonomousActivityAt: session.autonomousActivityAt,
            clientRunning: alive,
            summary: !alive
                ? "the client has gone; nothing here describes now"
                : (session.parentStateAt == nil
                   ? "this client has not reported a session state; unknown"
                   : "the session reported itself \(reported)"))
        state.attention = session.attention
        if let visible = session.handle as? VisibleClaudeHandle {
            state.surface = BridgeSurfaceState(terminal: "ghostty",
                                               windowID: visible.surface.windowID,
                                               tabID: visible.surface.tabID,
                                               terminalID: visible.surface.terminalID,
                                               open: visible.isRunning)
        } else if let recorded = session.state.surface {
            var closed = recorded
            closed.open = false           // the handle is gone, so the surface is not ours to claim
            state.surface = closed
        }
        return state
    }

    /// Bring a visible session's own terminal to the front. Only ever the surface this host
    /// created, by the id the terminal itself gave back — there is no pairing step and nothing is
    /// searched for.
    public func focus(sessionID: String) -> BridgeResponse {
        lock.lock()
        guard let session = sessions[sessionID] else {
            defer { lock.unlock() }
            return refusal(.notOwned, "This host did not start session \(sessionID).")
        }
        guard let visible = session.handle as? VisibleClaudeHandle else {
            defer { lock.unlock() }
            return refusal(.malformed,
                           "Session \(sessionID) has no terminal of its own. Start it with "
                           + "--terminal ghostty to get one.")
        }
        let snapshot = published(session)
        lock.unlock()

        guard visible.focus() else {
            return BridgeResponse(ok: false,
                                  error: BridgeError(code: .clientUnavailable,
                                                     message: "That terminal could not be brought "
                                                            + "forward; it may have been closed."),
                                  session: snapshot)
        }
        return BridgeResponse(ok: true, session: snapshot)
    }

    /// How long a reading stays a claim about now. Stated by the host so a caller does not have to
    /// know it — the whole point of reporting `stale` rather than only a timestamp.
    public static let freshnessWindow: TimeInterval = 30 * 60

    private func handleStatus(_ sessionID: String?) -> BridgeResponse {
        lock.lock(); defer { lock.unlock() }
        guard let sessionID else {
            // Every session, trimmed so the whole answer fits in one frame. A response too large to
            // read would be reported as a success and then vanish at the reader.
            let all = sessions.values.map(published).sorted { $0.startedAt < $1.startedAt }
            return BridgeHost.fitted(BridgeResponse(ok: true, sessions: all.map(BridgeHost.trimmed)))
        }
        guard let session = sessions[sessionID] else {
            return refusal(.notOwned, "This host does not own session \(sessionID).")
        }
        return BridgeHost.fitted(BridgeResponse(ok: true, session: BridgeHost.trimmed(published(session))))
    }

    private func handleEvents(_ sessionID: String, after sequence: Int) -> BridgeResponse {
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[sessionID] else {
            return refusal(.notOwned, "This host does not own session \(sessionID).")
        }
        let matching = session.events.filter { $0.sequence > sequence }
        let dropped = session.droppedEvents > 0 && sequence < (session.events.first?.sequence ?? 0) - 1
            ? session.droppedEvents : nil

        // Paged by **encoded bytes**, not by a count. A hundred events of four thousand characters
        // each is a megabyte, whatever the count limit says — and Unicode makes a character count a
        // guess at best. Events are added while the encoded response still fits.
        var page: [BridgeEvent] = []
        let state = BridgeHost.trimmed(session.state)
        var lastFitting = BridgeResponse(ok: true, session: state, events: [], droppedBefore: dropped,
                                         moreAvailable: matching.isEmpty ? nil : true,
                                         nextAfter: sequence)
        for event in matching.prefix(BridgeProtocol.maximumEventsPerResponse) {
            var candidate = page
            candidate.append(event)
            let attempt = BridgeResponse(ok: true, session: state, events: candidate,
                                         droppedBefore: dropped,
                                         moreAvailable: nil, nextAfter: event.sequence)
            guard BridgeHost.encodedSize(attempt) <= BridgeProtocol.maximumResponseBytes else { break }
            page = candidate
            lastFitting = attempt
        }
        let more = page.count < matching.count
        lastFitting.moreAvailable = more ? true : nil
        lastFitting.nextAfter = page.last?.sequence ?? sequence
        // If even one event will not fit beside the state, say so rather than looping for ever on
        // an empty page that always claims there is more.
        if page.isEmpty, !matching.isEmpty {
            lastFitting.events = []
            lastFitting.error = BridgeError(code: .limitReached,
                                            message: "The next event is too large to return in one "
                                                   + "frame; it is recorded but cannot be sent.")
            lastFitting.nextAfter = matching[0].sequence   // skip it rather than stall
            lastFitting.moreAvailable = matching.count > 1 ? true : nil
        }
        return BridgeHost.fitted(lastFitting)
    }

    /// The encoded size of a response, which is the only size that matters.
    static func encodedSize(_ response: BridgeResponse) -> Int {
        ((try? JSONCoding.encoder.encode(response))?.count ?? Int.max) + 1     // + the newline
    }

    /// A session state small enough to travel: the newest messages, with the rest counted.
    static func trimmed(_ state: BridgeSessionState) -> BridgeSessionState {
        guard state.messages.count > BridgeProtocol.maximumMessagesPerResponse else { return state }
        var copy = state
        copy.messagesOmitted = state.messages.count - BridgeProtocol.maximumMessagesPerResponse
        copy.messages = Array(state.messages.suffix(BridgeProtocol.maximumMessagesPerResponse))
        return copy
    }

    /// The last guard before an answer goes out: if it still will not fit, return something small
    /// and true rather than something large and lost.
    static func fitted(_ response: BridgeResponse) -> BridgeResponse {
        guard encodedSize(response) > BridgeProtocol.maximumResponseBytes else { return response }
        var trimmed = response
        trimmed.events = []
        trimmed.sessions = response.sessions.map { list in
            list.map { state in
                var small = state
                small.messagesOmitted = (small.messagesOmitted ?? 0) + small.messages.count
                small.messages = []
                return small
            }
        }
        if var session = trimmed.session {
            session.messagesOmitted = (session.messagesOmitted ?? 0) + session.messages.count
            session.messages = []
            trimmed.session = session
        }
        trimmed.error = BridgeError(code: .limitReached,
                                    message: "The full answer is larger than one frame; message "
                                           + "detail was omitted. Ask for one session at a time.")
        guard encodedSize(trimmed) <= BridgeProtocol.maximumResponseBytes else {
            return BridgeResponse(ok: false,
                                  error: BridgeError(code: .limitReached,
                                                     message: "The answer does not fit in one frame."))
        }
        return trimmed
    }

    private func handleStop(_ sessionID: String) -> BridgeResponse {
        lock.lock()
        guard let session = sessions[sessionID] else {
            defer { lock.unlock() }
            return refusal(.notOwned,
                           "This host did not start session \(sessionID), so it will not stop it.")
        }
        session.stopRequested = true
        session.inFlight = nil                    // stopping resolves the turn: nothing is owed now
        let handle = session.handle               // kept: only a confirmed exit releases it
        // Two different claims, kept apart. With a client still held, all that has happened is that
        // a stop was asked for — the answer says `stopping`, and only the process's own exit makes
        // it `stopped`. With nothing left to signal, it is already over.
        session.state.phase = (handle != nil && session.state.exitStatus == nil) ? .stopping : .stopped
        append(.note, to: session,
               text: session.state.phase == .stopping
                   ? "stop requested by the caller; waiting for the client to exit"
                   : "stopped by the caller")
        let snapshot = session.state
        lock.unlock()

        handle?.terminate()                       // outside the lock: terminating can block
        return BridgeResponse(ok: true, session: snapshot)
    }

    /// Stop everything this host started. Used on shutdown; touches nothing else.
    public func stopAll() {
        lock.lock()
        var handles: [BridgeClientHandle] = []
        for session in sessions.values {
            session.stopRequested = true
            // The handle is **kept** until the process confirms it has gone. Dropping it here made
            // `hasRunningClients` false immediately, so the host could exit while a child was still
            // alive and a delayed kill never arrived.
            if let handle = session.handle { handles.append(handle) }
            if session.state.phase != .stopped, session.state.phase != .stopping {
                session.state.phase = (session.handle != nil && session.state.exitStatus == nil)
                    ? .stopping : .stopped
                append(.note, to: session, text: "host shutting down")
            }
        }
        lock.unlock()
        handles.forEach { $0.terminate() }
    }

    /// Is anything this host started still alive?
    ///
    /// Answered from the client's own liveness and its recorded exit — not from whether we have
    /// stopped *asking* it to run. A shutdown that reported success while a child was still up was
    /// the previous version's worst habit.
    public var hasRunningClients: Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.contains { session in
            // A recorded exit is the end of the argument, even mid-launch: the process said so.
            if session.state.exitStatus != nil { return false }
            if session.launching { return true }
            guard let handle = session.handle else { return false }
            return handle.isRunning
        }
    }

    /// A turn that has been out for longer than `deadline` with no result is **uncertain**, and is
    /// left that way. Called by the host's own tick; never resends anything.
    public func markOverdue(after deadline: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let moment = now()
        for session in sessions.values {
            guard let inFlight = session.inFlight, !inFlight.unresolved,
                  let index = session.state.messages.lastIndex(where: { $0.messageID == inFlight.messageID })
            else { continue }
            // Anchored to *this* turn: when it was sent, acknowledged, or last did something. The
            // previous turn's activity says nothing about this one, and an unrelated frame from the
            // client must not keep postponing a real timeout.
            let message = session.state.messages[index]
            let anchor = max(message.sentAt, message.acknowledgedAt ?? message.sentAt,
                             session.lastRelevantActivityAt ?? message.sentAt)
            guard moment.timeIntervalSince(anchor) > deadline else { continue }
            session.state.phase = .uncertain
            session.state.messages[index].phase = .uncertain
            // Still owned. The client may answer late, and that answer belongs to *this* turn — it
            // must never be free to complete something sent afterwards.
            session.inFlight?.unresolved = true
            append(.note, to: session,
                   text: "no result for \(inFlight.messageID) in \(Int(deadline))s — uncertain, "
                       + "and nothing has been resent. The session will accept nothing new until "
                       + "this resolves or is stopped.",
                   messageID: inFlight.messageID)
        }
    }

    // MARK: - Reading the client

    /// One line of the client's stream-json output.
    ///
    /// Two rules run before anything is believed. **Attributable frames** — the ones that can change
    /// what we think happened — must carry this session's own id, exactly. And the id the client
    /// reports is only pinned once it has been validated, so a foreign frame cannot even name this
    /// session's client.
    func receive(_ line: String, for sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[sessionID] else { return }
        guard line.utf8.count <= BridgeProtocol.maximumFrameBytes else {
            append(.note, to: session, text: "a line from the client was too large to read")
            return
        }
        session.state.lastEventAt = now()

        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            append(.note, to: session, text: "a line from the client could not be read as JSON")
            return
        }

        let type = object["type"] as? String
        let reported = (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // Our own wrapper around the child's stderr. It carries no session id because it is not the
        // client speaking — it is the process failing — so it is recorded and attributes nothing.
        if type == "system", (object["subtype"] as? String) == "stderr" {
            append(.error, to: session, text: (object["text"] as? String).map { String($0.prefix(1_000)) })
            return
        }

        if BridgeHost.attributableTypes.contains(type ?? "") {
            guard let reported else {
                append(.note, to: session,
                       text: "ignored a \(type ?? "frame") with no session id — nothing without an "
                           + "identity may change this session's state")
                return
            }
            guard reported == sessionID else {
                append(.note, to: session, text: "ignored a frame naming a different session")
                return
            }
            // Validated, and only now recorded.
            if session.state.clientReportedSessionID == nil {
                session.state.clientReportedSessionID = reported
            }
        } else if let reported, reported != sessionID {
            append(.note, to: session, text: "ignored a frame naming a different session")
            return
        }

        // Once a stop has been asked for, this session is finished with — whether or not the process
        // has confirmed it yet. Late traffic is recorded and settles nothing.
        if session.stopRequested {
            append(.note, to: session, text: "a \(type ?? "frame") arrived after the session was stopped")
            return
        }

        // Task lifecycle frames are a separate account entirely: they describe work running behind
        // the session, and they never settle a turn. Validated by exact session id, deduplicated by
        // the client's own event id, and refused when they would move a settled job backwards.
        if let frame = BackgroundLifecycleFrame(object) {
            switch session.jobs.apply(frame, ownedBy: sessionID, at: now()) {
            case .recorded:
                append(.note, to: session,
                       text: "background job \(frame.taskID): \(frame.kind.rawValue)")
            case .duplicate:
                break                                    // already applied; nothing new happened
            case .wrongSession:
                append(.note, to: session, text: "ignored a task frame naming a different session")
            case .outOfOrder:
                append(.note, to: session,
                       text: "a late frame for background job \(frame.taskID) was not applied; "
                           + "its outcome is already settled")
            }
            return
        }

        switch type {
        case "user":
            acknowledge(object, in: session)

        case "assistant":
            guard session.inFlight != nil else {
                // The session is working on its own — a monitor woke it, or a task reported back.
                // That is real activity and is recorded as such. What it is *not* is an answer to
                // anything: no turn is opened, and nothing sent later inherits it.
                session.autonomousActivityAt = now()
                append(.note, to: session,
                       text: "the session is working without a turn in flight; recorded as its own "
                           + "activity and attributed to no prompt")
                return
            }
            session.state.phase = .active
            session.lastRelevantActivityAt = now()
            append(.assistantText, to: session, text: BridgeHost.assistantText(object),
                   messageID: session.inFlight?.messageID)

        case "system":
            if let subtype = object["subtype"] as? String, subtype == "session_state_changed" {
                // The client's own account of what its main turn is doing. Recorded as its own
                // field: it answers a different question from the phase of our last message.
                let reported = (object["state"] as? String) ?? ""
                session.parentState = ["idle", "running", "requires_action"].contains(reported)
                    ? (reported == "requires_action" ? "requiresAction"
                       : reported == "running" ? "working" : "idle")
                    : "unknown"
                session.parentStateAt = now()
                append(.note, to: session, text: "session state: \(session.parentState)")
                return
            }
            if let subtype = object["subtype"] as? String, subtype == "background_tasks_changed" {
                // A level signal with replace semantics: the whole live set, ids only. Replacing a
                // set is destructive, so what arrives has to be a set we can actually read.
                //
                // A missing `tasks`, one that is not an array, or entries without ids are not an
                // empty membership — they are a payload we could not read, and coercing them into
                // "nothing is running" would mark every known job absent on a malformed frame.
                guard reported == sessionID else {
                    // A level signal is only about the session it names. Unattributed, it replaces
                    // nothing: this is the one frame here that can erase state wholesale.
                    append(.note, to: session,
                           text: "ignored a background task set that names no session")
                    return
                }
                guard let entries = object["tasks"] as? [[String: Any]] else {
                    session.jobs.markPartialCoverage()
                    append(.note, to: session,
                           text: "a background task set arrived without a readable task list; what "
                               + "was already known is kept, and coverage is partial")
                    return
                }
                let ids = entries.compactMap { BackgroundRegistry.bounded($0["task_id"]) }
                guard ids.count == entries.count else {
                    session.jobs.markPartialCoverage()
                    append(.note, to: session,
                           text: "a background task set contained \(entries.count - ids.count) "
                               + "entry(s) with no usable id; it is not treated as the whole set")
                    return
                }
                let ambient = Set(entries.filter { ($0["ambient"] as? Bool) == true }
                    .compactMap { BackgroundRegistry.bounded($0["task_id"]) })
                session.jobs.applyMembership(taskIDs: ids, ambient: ambient,
                                             ownedBy: sessionID, at: now())
                append(.note, to: session, text: "background task set: \(ids.count) live")
                return
            }
            if let subtype = object["subtype"] as? String, subtype.contains("permission") {
                // Permissions belong to Claude Code. This host does not answer them and does not
                // pretend to: it records the fact and lets the caller see it.
                session.state.permissionNote = "The client asked for a permission decision. This "
                    + "bridge does not answer permission prompts."
                append(.permission, to: session, text: session.state.permissionNote)
            } else {
                append(.note, to: session, text: object["subtype"] as? String)
            }

        case "result":
            complete(object, in: session)

        default:
            append(.note, to: session, text: type)
        }
    }

    /// The frame types that can change what we believe. Each must name this session.
    static let attributableTypes: Set<String> = ["user", "assistant", "result"]

    /// The echo Claude Code sends back for `--replay-user-messages`.
    ///
    /// It acknowledges our turn only if it is a **user message of text blocks whose whole text is
    /// exactly what we sent**, correlation footer and all. Containing the correlation id somewhere
    /// is not enough: a tool result quoting it, or an edited copy, is not our message coming back.
    private func acknowledge(_ object: [String: Any], in session: Session) {
        guard let inFlight = session.inFlight else {
            append(.note, to: session, text: "a user echo arrived with no turn in flight")
            return
        }
        guard let message = object["message"] as? [String: Any],
              (message["role"] as? String) == "user" else {
            append(.note, to: session, text: "a user frame without a user-role message")
            return
        }
        // The documented join key first. When the client stamps our own uuid on the replay, that
        // is identity rather than resemblance — and it tells us this producer supports the key at
        // all, which decides how much the text match has to carry later.
        if let stamped = BackgroundRegistry.bounded(object["uuid"]) {
            if stamped == inFlight.clientUUID {
                session.inFlight?.joinKeyConfirmed = true
                // Deliberately *not* proof that this client stamps join keys on results. The
                // replay carries our uuid because it is a replay of the frame we wrote; every
                // producer does that, including ones that never stamp `user_message_uuid` on a
                // result. Only a reply frame carrying the field proves support.
            } else if session.inFlight?.joinKeyConfirmed == true {
                append(.note, to: session,
                       text: "a replay carrying a different client uuid; not this turn's echo")
                return
            }
        }
        guard let text = BridgeHost.textOnlyBody(message) else {
            append(.note, to: session, text: "a user frame that was not plain text — not our message")
            return
        }
        guard text == inFlight.sentBody else {
            append(.note, to: session,
                   text: "a user echo whose text is not the message this host sent")
            return
        }
        guard !session.acknowledgedCorrelations.contains(inFlight.correlationID) else {
            return                                   // a repeat of one already counted
        }
        session.acknowledgedCorrelations.insert(inFlight.correlationID)
        session.state.phase = .clientAcknowledged
        session.lastRelevantActivityAt = now()
        if let index = session.state.messages.lastIndex(where: { $0.messageID == inFlight.messageID }) {
            session.state.messages[index].acknowledgedAt = now()
            session.state.messages[index].phase = .clientAcknowledged
        }
        append(.acknowledged, to: session, messageID: inFlight.messageID)
    }

    /// A result settles **the one turn this session owns**, and nothing else.
    ///
    /// Four things are checked, because a result frame carries no turn of its own:
    ///
    /// - **The documented shape.** `is_error` must be there. "No error was mentioned, so it worked"
    ///   is exactly the optimism to avoid.
    /// - **Its own identity, not the session's.** `session_id` names the *conversation*, and a
    ///   conversation has many results — it cannot tell one turn's answer from another's. Each
    ///   result is remembered by its own identity, and one that already settled a turn here settles
    ///   nothing again. Without this, a client that replays an old frame after the next prompt has
    ///   gone out marks that new turn complete with the previous turn's answer.
    /// - **A turn to settle.** Nothing in flight means nothing to finish.
    /// - **Success needs the turn to have been acknowledged.** Claiming a turn succeeded when the
    ///   client never echoed the prompt back is claiming an outcome for something we cannot show it
    ///   received. A *failure* is allowed through without an echo: a client that dies on the way in
    ///   reports its error before any replay, and refusing to record that would leave the session
    ///   owned by a turn that can never resolve.
    private func complete(_ object: [String: Any], in session: Session) {
        guard let isError = object["is_error"] as? Bool else {
            append(.note, to: session,
                   text: "a result frame without `is_error` — not a shape this host will read as an outcome")
            return
        }
        let text = (object["result"] as? String).map { String($0.prefix(BridgeProtocol.maximumEventTextLength)) }
        let identity = BridgeHost.resultIdentity(object)
        let keys = BridgeHost.joinKeys(object)
        let replayed = session.settledResultIdentities.contains(identity)

        // **Evidence first, attribution second.** What this frame teaches us about the *producer*
        // is true whether or not there is a turn to settle: a client that stamps a join key on a
        // result between two submissions still stamps them. Recording that only when something was
        // in flight left a gap where a later keyless replay could take the older-client path.
        switch keys {
        case .named, .stated:
            session.joinKeysSeen = true
        case .absent:
            break
        }

        // A hand-back the session wrote is an ask, and it survives the turn being settled — but it
        // is raised only from a frame we have **validated**, and never from one we have already
        // seen. Replaying an old hand-back after the user has dealt with it must not reopen it
        // against whatever is in flight now.
        func raiseAcceptanceIfOffered(attributedTo messageID: String?) {
            guard !replayed, let text = object["result"] as? String else { return }
            let reading = FinalHandoff.readStandaloneAcceptance(text)
            guard reading.awaitsUserAcceptance else { return }
            session.attention = BridgeAttentionState(
                messageID: messageID, kind: "acceptance", excerpt: reading.excerpt,
                raisedAt: now(), open: true)
            append(.note, to: session,
                   text: "the session handed work back for you to test or review; only a reply or "
                       + "an explicit resolution closes that",
                   messageID: messageID)
        }

        guard let inFlight = session.inFlight else {
            // A result with nothing outstanding settles nothing: marking a later turn done on an
            // earlier turn's answer is precisely the bug this replaces. It can still be a genuine
            // autonomous hand-back, which belongs to no submitted message and says so.
            switch keys {
            case .named(let named):
                // It names a send we know about. Recorded, and still settling nothing.
                append(.note, to: session,
                       text: "a result naming \(named.count) earlier send(s) arrived with no turn "
                           + "in flight")
            case .stated, .absent:
                append(.note, to: session, text: "a result arrived with no turn in flight")
            }
            if !replayed {
                session.settledResultIdentities.insert(identity)
                session.settledResults.append(identity)
                if session.settledResults.count > BridgeProtocol.maximumSettledResults {
                    session.settledResultIdentities.remove(session.settledResults.removeFirst())
                }
                raiseAcceptanceIfOffered(attributedTo: nil)
            }
            return
        }
        guard !replayed else {
            append(.note, to: session,
                   text: "a result this session has already settled arrived again; it settles nothing "
                       + "further, and message \(inFlight.messageID) is still outstanding",
                   messageID: inFlight.messageID)
            return
        }
        /// Leave the turn outstanding and say why. Used wherever attribution cannot be established:
        /// an unattributable result is not this turn's outcome, and it is not nothing either.
        func unattributed(_ why: String) {
            session.state.phase = .uncertain
            if let index = session.state.messages.lastIndex(where: { $0.messageID == inFlight.messageID }) {
                session.state.messages[index].phase = .uncertain
            }
            session.inFlight?.unresolved = true
            append(.note, to: session,
                   text: why + " — it cannot be attributed to \(inFlight.messageID), which stays "
                       + "outstanding", messageID: inFlight.messageID)
        }

        // Which send does this answer? The rules differ by *how* the frame answers that, and the
        // difference decides whether a background result can land on a prompt somebody typed.
        switch keys {
        case .named(let named):
            guard named.contains(inFlight.clientUUID) else {
                append(.note, to: session,
                       text: "a result whose user_message_uuid names a different send; message "
                           + "\(inFlight.messageID) is still outstanding",
                       messageID: inFlight.messageID)
                return
            }

        case .stated:
            // The producer sent the field and it carries no usable key: null, malformed, or its
            // two spellings disagreeing. That is a client which *supports* the key saying this
            // turn has no client uuid — a synthetic or scheduled turn. It is not the silence of an
            // older client, and it never settles a prompt a caller sent. Failures included: a
            // wrongly attributed failure is a wrong attribution.
            unattributed("a result whose user_message_uuid is explicitly absent or unusable, which "
                         + "means a turn nobody here submitted")
            return

        case .absent:
            // No field at all. Only here is older-producer compatibility in play — and only when
            // nothing else about this session suggests something else could have produced it.
            // Once this client has ever stamped a key, its absence is meaningful rather than old.
            let concurrency = session.autonomousActivityAt != nil || !session.jobs.jobs.isEmpty
            if session.joinKeysSeen {
                unattributed("a result with no user_message_uuid from a client that stamps one")
                return
            }
            if concurrency {
                unattributed("a result with no user_message_uuid while this session also had work "
                             + "running or was acting on its own")
                return
            }
        }
        guard isError || session.acknowledgedCorrelations.contains(inFlight.correlationID) else {
            append(.note, to: session,
                   text: "a success result arrived for \(inFlight.messageID), which the client never "
                       + "echoed back — there is no evidence it ever received that prompt, so this is "
                       + "not read as its outcome",
                   messageID: inFlight.messageID)
            return
        }
        session.settledResultIdentities.insert(identity)
        session.settledResults.append(identity)
        if session.settledResults.count > BridgeProtocol.maximumSettledResults {
            session.settledResultIdentities.remove(session.settledResults.removeFirst())
        }
        raiseAcceptanceIfOffered(attributedTo: inFlight.messageID)
        session.state.phase = isError ? .failed : .completed
        if let index = session.state.messages.lastIndex(where: { $0.messageID == inFlight.messageID }) {
            session.state.messages[index].completedAt = now()
            session.state.messages[index].phase = isError ? .failed : .completed
        }
        session.inFlight = nil                       // genuinely resolved: this is what releases it
        session.lastRelevantActivityAt = now()
        append(isError ? .error : .result, to: session, text: text, messageID: inFlight.messageID)
    }

    func clientExited(_ sessionID: String, status: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[sessionID] else { return }
        session.state.exitStatus = status
        session.handle = nil                     // released here, and only here: the process is gone
        append(.exited, to: session, text: "client exited with status \(status)")

        // A turn that was still out when the process went is unknown — not finished, not failed.
        if let inFlight = session.inFlight,
           let index = session.state.messages.lastIndex(where: { $0.messageID == inFlight.messageID }) {
            session.state.messages[index].phase = status == 0 ? .uncertain : .failed
            session.inFlight = nil
        }
        switch session.state.phase {
        case .stopping:
            // The one transition that turns a request into a fact.
            session.state.phase = .stopped
        case .completed, .stopped, .failed:
            break                                    // already settled; an exit changes nothing
        default:
            // A stop asked for before the handle existed still ends as a confirmed stop.
            session.state.phase = session.stopRequested ? .stopped
                : (status == 0 ? .uncertain : .failed)
        }
    }

    // MARK: - Helpers

    private func append(_ kind: BridgeEvent.Kind, to session: Session,
                        text: String? = nil, messageID: String? = nil) {
        session.state.lastSequence += 1
        session.events.append(BridgeEvent(sequence: session.state.lastSequence, at: now(),
                                          kind: kind, text: text.map { String($0.prefix(4_000)) },
                                          messageID: messageID))
        if session.events.count > BridgeProtocol.maximumRetainedEvents {
            let excess = session.events.count - BridgeProtocol.maximumRetainedEvents
            session.events.removeFirst(excess)
            session.droppedEvents += excess
        }
        session.state.lastEventAt = now()
    }

    private func refusal(_ code: BridgeError.Code, _ message: String) -> BridgeResponse {
        BridgeResponse(ok: false, error: BridgeError(code: code, message: message))
    }

    private func isApproved(_ path: String) -> Bool {
        approvedRoots.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// Resolve a path all the way through its symlinks, or refuse it.
    ///
    /// Comparing an unresolved path against an approved root is how a link inside the root reaches
    /// somewhere else entirely.
    static func resolve(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let real = realpath(expanded, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    static func normalise(_ path: String) -> String {
        resolve(path) ?? URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.path
    }

    /// Short, printable, and present. Anything else is refused before it reaches a data structure.
    static func isUsableIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= BridgeProtocol.maximumIdentifierLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    /// A real digest, so a reused message id can be checked without keeping the prompt.
    ///
    /// `Hasher` was wrong here twice over: it is seeded per process, so it does not compare across
    /// runs, and formatting a 64-bit value that only ever held 32 bits of entropy made it *look*
    /// like a full-width hash. This is SHA-256 over the UTF-8 bytes, hex, no pretending.
    public static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What a frame says about which send it answers.
    ///
    /// Three answers, and the difference between them is the whole point:
    ///
    /// - **`.named`** — usable keys. Ours is in the set, or it is not.
    /// - **`.stated(none)`** — the producer *sent* the field and it is null, empty, malformed, or
    ///   its two spellings disagree. That is a producer which supports the key telling us this turn
    ///   has no client uuid — a synthetic or scheduled turn. It is emphatically **not** the absence
    ///   an older client produces, and treating it as one is how a background result settles a
    ///   prompt somebody typed.
    /// - **`.absent`** — the field is not there at all. Only then is older-producer compatibility
    ///   in play, and even then only when nothing else suggests concurrency.
    enum JoinKeys {
        case named(Set<String>)
        case stated
        case absent
    }

    static func joinKeys(_ object: [String: Any]) -> JoinKeys {
        let hasSingle = object.keys.contains("user_message_uuid")
        let hasList = object.keys.contains("user_message_uuids")
        guard hasSingle || hasList else { return .absent }

        var listed: Set<String>?
        if hasList {
            guard let raw = object["user_message_uuids"] as? [Any] else { return .stated }
            let keys = Set(raw.prefix(64).compactMap { BackgroundRegistry.bounded($0) })
            guard keys.count == min(raw.count, 64) else { return .stated }   // malformed entries
            listed = keys
        }
        var single: String?
        if hasSingle {
            guard let key = BackgroundRegistry.bounded(object["user_message_uuid"]) else {
                return .stated                                   // explicit null, or not a string
            }
            single = key
        }
        // The documented contract is that the list always contains the single value. If it does
        // not, the two disagree and neither is trustworthy.
        if let single, let listed, !listed.contains(single) { return .stated }
        let keys = (listed ?? []).union(single.map { [$0] } ?? [])
        return keys.isEmpty ? .stated : .named(keys)
    }

    /// What makes one result *that* result.
    ///
    /// **The fallback is deliberately strict.** The documented result frame carries a required
    /// `uuid`, so a conforming client always lands on the first branch. A producer that omits it
    /// gets an identity derived from the outcome-bearing fields, and two genuinely different turns
    /// that emit byte-identical text would then collide — the second is refused and its turn stays
    /// outstanding rather than being settled. That is the safe side of the trade: a turn left
    /// visibly unresolved can be seen and stopped, while an old answer silently settling a new
    /// prompt cannot be seen at all.
    ///
    /// The documented result frame carries its own `uuid`, and that is used when it is there. When
    /// it is not, the identity is a digest of the parts that decide an outcome — never the session
    /// id, which names the conversation rather than the answer. Two genuinely different answers
    /// still differ; the same frame arriving twice does not.
    static func resultIdentity(_ object: [String: Any]) -> String {
        if let uuid = (object["uuid"] as? String), !uuid.isEmpty { return "uuid:" + uuid }
        let parts = [
            "v1",
            "subtype=\((object["subtype"] as? String) ?? "")",
            "is_error=\((object["is_error"] as? Bool).map(String.init) ?? "")",
            "result=\((object["result"] as? String) ?? "")",
        ]
        return "derived:" + fingerprint(parts.joined(separator: "\u{1}"))
    }

    /// Exactly what is written into the message this host sends — and therefore exactly what the
    /// echo has to say back.
    static func messageBody(text: String, correlationID: String) -> String {
        "\(text)\n\n[warden-correlation: \(correlationID)]"
    }

    /// The stream-json user frame, carrying a **client uuid**.
    ///
    /// That uuid is the join key the client stamps back on the turn's first reply and on its
    /// result (`user_message_uuid`, and `user_message_uuids` for a merged batch). Without it the
    /// only correlation available is the text of the message coming home, which cannot tell a
    /// reply to *this* send from a reply to something the session did on its own.
    static func frame(body: String, sessionID: String, clientUUID: String) -> String {
        let object: [String: Any] = [
            "type": "user",
            "uuid": clientUUID,
            "message": ["role": "user", "content": [["type": "text", "text": body]]],
            "parent_tool_use_id": NSNull(),
            "session_id": sessionID,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else { return "" }
        return line
    }

    /// The text of a message made only of text blocks, or nothing. A tool result, an image, or any
    /// other block type means this is not the message we sent coming back.
    static func textOnlyBody(_ message: [String: Any]) -> String? {
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty else { return nil }
        var parts: [String] = []
        for block in blocks {
            guard (block["type"] as? String) == "text", let text = block["text"] as? String else {
                return nil
            }
            parts.append(text)
        }
        return parts.joined()
    }

    /// The stream-json frame Claude Code expects on stdin.
    ///
    /// The correlation id is written into the text itself, because that is what comes back in the
    /// replayed echo. Without something identifying in the message, "the client replied" cannot be
    /// told from "the client replayed something else".
    static func userMessageFrame(text: String, sessionID: String, correlationID: String,
                                 clientUUID: String = UUID().uuidString) -> String {
        frame(body: messageBody(text: text, correlationID: correlationID), sessionID: sessionID,
              clientUUID: clientUUID)
    }

    static func userText(_ object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func assistantText(_ object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return String(text.prefix(4_000)) }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(4_000))
    }
}
