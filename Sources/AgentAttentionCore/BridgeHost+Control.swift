import Foundation

/// One adoption, from `prepare` to done.
struct AdoptionTicket {
    let requestID: String
    let sessionID: String
    let cwd: String
    let originalPID: Int32
    let originalStartedAt: Double
    let tty: String?
    var detach: BridgeRequest.AdoptRequest.Detach
    var phase: BridgeAdoptionState.Phase
    var originalProcess = "unknown"
    var checkedAt: Date
    let createdAt: Date
    var nextStep = ""
    var blockers: [String] = []
    /// A signal has been sent once. It is never sent twice.
    var exitRequested = false

    var isOpen: Bool { phase != .adopted && phase != .cancelled }

    var state: BridgeAdoptionState {
        BridgeAdoptionState(requestID: requestID, sessionID: sessionID, phase: phase,
                            detach: detach.rawValue, cwd: cwd, originalPID: originalPID,
                            originalStartedAt: originalStartedAt, tty: tty,
                            originalProcess: originalProcess, checkedAt: checkedAt,
                            createdAt: createdAt, nextStep: nextStep, blockers: blockers)
    }
}

extension BridgeHost {
    // MARK: - Reading

    /// Owned and observed sessions side by side, never merged: a caller has to be able to tell
    /// which ones it can send to.
    func listSessions() -> BridgeResponse {
        lock.lock()
        let owned = sessions.values.map(published).sorted { $0.startedAt < $1.startedAt }
            .map(BridgeHost.trimmed)
        let adoptionStates = adoptionOrder.compactMap { adoptions[$0]?.state }
        lock.unlock()

        guard let observed else {
            return BridgeHost.fitted(BridgeResponse(ok: true, sessions: owned,
                                                    adoptions: adoptionStates))
        }
        let report = observed.rows()
        let rows = report.sessions.sorted { $0.lastEventAgeSeconds < $1.lastEventAgeSeconds }
        let shown = Array(rows.prefix(BridgeProtocol.maximumObservedSessions))
        return BridgeHost.fitted(BridgeResponse(
            ok: true, sessions: owned, observed: shown,
            observedOmitted: rows.count > shown.count ? rows.count - shown.count : nil,
            observedTrustworthy: report.trustworthy, observedWarnings: report.warnings,
            adoptions: adoptionStates))
    }

    /// Recent conversation, bounded, from the one reader that checks identity before it opens
    /// anything. An owned session also brings its own most recent events.
    func context(sessionID: String, maxMessages: Int?) -> BridgeResponse {
        let limit = min(max(maxMessages ?? 10, 1), SessionContextReader.maximumMessages)
        lock.lock()
        let owned = sessions[sessionID]
        let recent = owned.map { session in
            Array(session.events.filter { [.assistantText, .result, .error].contains($0.kind) }
                .suffix(limit))
        }
        lock.unlock()

        var answer = observed?.context(sessionID: sessionID)
        if owned == nil, answer == nil || answer?.identity == .notTracked {
            return refusal(.notOwned, "Warden neither owns nor observes session \(sessionID); "
                           + "nothing was read.")
        }
        if var read = answer?.context {
            read.messages = Array(read.messages.suffix(limit))
            answer?.context = read
        }
        return BridgeHost.fitted(BridgeResponse(ok: true, events: recent, context: answer))
    }

    func summary(sessionID: String) -> BridgeResponse {
        lock.lock()
        let owned = sessions[sessionID].map(published)
        lock.unlock()
        let answer = observed?.context(sessionID: sessionID)
        let row = observed?.rows().sessions.first { $0.sessionID == sessionID }
        guard owned != nil || row != nil else {
            return refusal(.notOwned, "Warden neither owns nor observes session \(sessionID); "
                           + "there is nothing to summarise.")
        }
        return BridgeResponse(ok: true, summary: GroundedSummary.build(
            sessionID: sessionID, row: row, context: answer, owned: owned, now: now()))
    }

    // MARK: - Writers

    /// Nil when nothing but this host's own client holds the conversation — or when the session
    /// was never adopted, and so has no transcript anyone else could have opened.
    func foreignWriterRefusal(for sessionID: String) -> BridgeResponse? {
        lock.lock()
        guard let session = sessions[sessionID], session.state.adoptedFrom != nil,
              let observed else {
            lock.unlock()
            return nil
        }
        let own: Set<Int32> = session.handle.map { [$0.pid] } ?? []
        lock.unlock()
        guard let holders = observed.foreignHolders(sessionID: sessionID, excluding: own) else {
            return refusal(.writerConflict,
                           "Could not confirm that nothing else holds conversation \(sessionID) — "
                           + "Claude Code's session registry could not be read. Nothing was written.")
        }
        guard holders.isEmpty else {
            let pids = holders.map { String($0.pid) }.joined(separator: ", ")
            return refusal(.writerConflict,
                           "Another Claude process (pid \(pids)) also holds conversation \(sessionID). "
                           + "Two writers would interleave in one transcript, so nothing was written. "
                           + "Exit the other one, or stop this session.")
        }
        return nil
    }

    // MARK: - Adoption

    func handleAdopt(_ request: BridgeRequest.AdoptRequest) -> BridgeResponse {
        guard request.authorization?.isUsable == true else {
            return refusal(.authorizationRequired,
                           "Adoption needs an authorization: a confirmed statement that a person "
                           + "approved taking this session over. Nothing was done.")
        }
        guard BridgeHost.isUsableIdentifier(request.requestID) else {
            return refusal(.malformed, "A request id must be 1…\(BridgeProtocol.maximumIdentifierLength) printable characters.")
        }
        guard SessionContextReader.isPlausibleSessionID(request.sessionID) else {
            return refusal(.malformed, "\(request.sessionID) is not a full session id.")
        }
        guard observed != nil else {
            return refusal(.notAdoptable, "This host has no view of the sessions Warden observes, so "
                           + "it cannot take one over.")
        }
        switch request.action {
        case .prepare: return prepareAdoption(request)
        case .complete: return completeAdoption(request)
        case .cancel: return cancelAdoption(request)
        }
    }

    private func prepareAdoption(_ request: BridgeRequest.AdoptRequest) -> BridgeResponse {
        let terminate = request.detach == .terminate
        lock.lock()
        if let existing = adoptions[request.requestID] {
            lock.unlock()
            guard existing.sessionID == request.sessionID else {
                return refusal(.idempotencyConflict,
                               "Request id \(request.requestID) already names the adoption of "
                               + "\(existing.sessionID).")
            }
            return refreshAdoption(request.requestID, terminate: terminate)
        }
        if let session = sessions[request.sessionID] {
            lock.unlock()
            return refusal(.notAdoptable, session.state.adoptedFrom.map {
                "Session \(request.sessionID) was already adopted, under request \($0)."
            } ?? "Session \(request.sessionID) is already one this host started.")
        }
        if let open = adoptions.values.first(where: { $0.sessionID == request.sessionID && $0.isOpen }) {
            lock.unlock()
            return refusal(.idempotencyConflict,
                           "Session \(request.sessionID) is already being adopted under request "
                           + "\(open.requestID). Complete or cancel that one.")
        }
        lock.unlock()

        guard let observed, let record = observed.record(sessionID: request.sessionID) else {
            return refusal(.notAdoptable, "Warden does not observe session \(request.sessionID), so "
                           + "there is nothing here to take over.")
        }
        guard let pid = record.pid, let started = record.pidStartedAt else {
            return refusal(.notAdoptable,
                           "The Claude process behind \(request.sessionID) was never identified, so "
                           + "there is no way to prove it has exited. It cannot be adopted.")
        }
        guard let cwd = BridgeHost.resolve(record.cwd), isApproved(cwd) else {
            return refusal(.directoryNotApproved,
                           "\(record.cwd) is not inside an approved project directory. Add its project "
                           + "to bridge.json to allow adopting sessions there.")
        }
        guard observed.transcriptExists(sessionID: request.sessionID) else {
            return refusal(.notAdoptable, "No transcript exists for \(request.sessionID), so there is "
                           + "no conversation to continue.")
        }

        lock.lock()
        // Checked again: another prepare may have landed while this one was reading.
        if adoptions[request.requestID] != nil
            || adoptions.values.contains(where: { $0.sessionID == request.sessionID && $0.isOpen })
            || sessions[request.sessionID] != nil {
            lock.unlock()
            return refusal(.idempotencyConflict,
                           "Session \(request.sessionID) was claimed by another request just now.")
        }
        while adoptions.count >= BridgeProtocol.maximumAdoptions,
              let oldest = adoptionOrder.first(where: { adoptions[$0]?.isOpen == false }) {
            adoptions.removeValue(forKey: oldest)
            adoptionOrder.removeAll { $0 == oldest }
        }
        guard adoptions.count < BridgeProtocol.maximumAdoptions else {
            lock.unlock()
            return refusal(.limitReached, "This host is holding as many open adoptions as it will.")
        }
        adoptions[request.requestID] = AdoptionTicket(
            requestID: request.requestID, sessionID: request.sessionID, cwd: cwd,
            originalPID: pid, originalStartedAt: started, tty: record.tty,
            detach: request.detach ?? .user, phase: .awaitingDetach, checkedAt: now(),
            createdAt: now())
        adoptionOrder.append(request.requestID)
        lock.unlock()
        return refreshAdoption(request.requestID, terminate: terminate)
    }

    /// Look again at everything an adoption waits on, and — only when asked, only once, and only
    /// for an idle session — ask the original client to leave.
    private func refreshAdoption(_ requestID: String, terminate: Bool) -> BridgeResponse {
        lock.lock()
        guard var ticket = adoptions[requestID], let observed else {
            lock.unlock()
            return refusal(.notAdoptable, "Nothing was prepared under request \(requestID).")
        }
        lock.unlock()
        guard ticket.isOpen else { return BridgeResponse(ok: true, adoption: ticket.state) }

        var original = observed.processState(pid: ticket.originalPID, startedAt: ticket.originalStartedAt)
        var terminateRefusal: BridgeError?
        if terminate, original == .alive, !ticket.exitRequested {
            let record = observed.record(sessionID: ticket.sessionID)
            if record?.activity == SessionActivityState.working.rawValue {
                terminateRefusal = BridgeError(code: .notAdoptable,
                    message: "It is working on a turn right now, and Warden will not interrupt one. "
                           + "Wait for it to finish, or exit it yourself.")
            } else if (record?.backgroundRunning ?? 0) > 0 {
                terminateRefusal = BridgeError(code: .notAdoptable,
                    message: "It still has background work running, which would end with it. "
                           + "Wait for that work, or exit it yourself.")
            } else if claimExit(requestID) {
                // Claimed on the record *before* the signal, so a cancel that lands meanwhile can
                // never report "left exactly as it was" about a client that was asked to leave.
                if observed.requestExit(pid: ticket.originalPID, startedAt: ticket.originalStartedAt) {
                    ticket.exitRequested = true
                    ticket.detach = .terminate
                    // A short, bounded wait for the exit to be *seen*. Asking is not the same as it
                    // having gone, and the phase says which one this is.
                    let deadline = Date().addingTimeInterval(adoptionExitWait)
                    repeat {
                        usleep(100_000)
                        original = observed.processState(pid: ticket.originalPID,
                                                         startedAt: ticket.originalStartedAt)
                    } while original == .alive && Date() < deadline
                } else {
                    releaseExitClaim(requestID)
                    terminateRefusal = BridgeError(code: .notAdoptable,
                        message: "Pid \(ticket.originalPID) could not be confirmed as the same Claude "
                               + "process, so nothing was signalled.")
                }
            }
        }

        let where_ = ticket.tty.map { " on \($0)" } ?? ""
        ticket.blockers = []
        switch original {
        case .alive:
            ticket.originalProcess = "alive"
            ticket.phase = ticket.exitRequested ? .detaching : .awaitingDetach
            ticket.blockers = ["The original Claude client (pid \(ticket.originalPID)\(where_)) is still running."]
            ticket.nextStep = ticket.exitRequested
                ? "Warden asked pid \(ticket.originalPID) to exit and it has not gone yet. Call complete "
                  + "once it has — it is never signalled twice or forced."
                : "Exit Claude in its terminal\(where_) (type /exit), or prepare again with detach "
                  + "terminate while it is idle. Then call complete."
        case .unknown:
            ticket.originalProcess = "unknown"
            ticket.phase = .awaitingDetach
            ticket.blockers = ["Whether pid \(ticket.originalPID) is still running could not be checked."]
            ticket.nextStep = "Nothing can proceed until the original client can be checked."
        case .dead:
            ticket.originalProcess = "gone"
            switch observed.foreignHolders(sessionID: ticket.sessionID, excluding: []) {
            case .none:
                ticket.phase = .awaitingDetach
                ticket.blockers = ["Claude Code's session registry could not be read, so nothing "
                                   + "proves the conversation is free."]
                ticket.nextStep = "Try again; the conversation is not resumed on an unproven claim."
            case .some(let holders) where !holders.isEmpty:
                ticket.phase = .awaitingDetach
                ticket.blockers = ["Another Claude process holds this conversation: pid "
                                   + holders.map { String($0.pid) }.joined(separator: ", ") + "."]
                ticket.nextStep = "Exit that client too, then call complete."
            case .some:
                ticket.phase = .ready
                ticket.nextStep = "Nothing holds the conversation. Call complete to resume it under Warden."
            }
        }
        ticket.checkedAt = now()

        lock.lock()
        // Written back only if nothing finished or cancelled it meanwhile.
        if adoptions[requestID]?.isOpen == true { adoptions[requestID] = ticket }
        let state = adoptions[requestID]?.state ?? ticket.state
        lock.unlock()
        return BridgeResponse(ok: terminateRefusal == nil, error: terminateRefusal, adoption: state)
    }

    /// Mark an open adoption as asking its client to exit. False when it is no longer open, or has
    /// asked already — then nothing may be signalled.
    private func claimExit(_ requestID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let ticket = adoptions[requestID], ticket.isOpen, !ticket.exitRequested else { return false }
        adoptions[requestID]?.exitRequested = true
        adoptions[requestID]?.detach = .terminate
        return true
    }

    private func releaseExitClaim(_ requestID: String) {
        lock.lock(); defer { lock.unlock() }
        if adoptions[requestID]?.isOpen == true { adoptions[requestID]?.exitRequested = false }
    }

    private func completeAdoption(_ request: BridgeRequest.AdoptRequest) -> BridgeResponse {
        lock.lock()
        guard let ticket = adoptions[request.requestID] else {
            lock.unlock()
            return refusal(.notAdoptable, "Nothing was prepared under request \(request.requestID). "
                           + "Prepare first.")
        }
        guard ticket.sessionID == request.sessionID else {
            lock.unlock()
            return refusal(.idempotencyConflict, "Request \(request.requestID) names the adoption of "
                           + "\(ticket.sessionID), not \(request.sessionID).")
        }
        if ticket.phase == .adopted {
            // A retry of a completed adoption is the same adoption, not a second client.
            let owned = sessions[ticket.sessionID].map(published)
            lock.unlock()
            return BridgeResponse(ok: true, session: owned, adoption: ticket.state)
        }
        guard ticket.phase != .cancelled else {
            lock.unlock()
            return refusal(.notAdoptable, "Request \(request.requestID) was cancelled.")
        }
        lock.unlock()

        let refreshed = refreshAdoption(request.requestID, terminate: false)
        guard refreshed.adoption?.phase == .ready else {
            return BridgeResponse(ok: false, error: BridgeError(
                code: .writerConflict,
                message: "The conversation is not free yet: "
                    + (refreshed.adoption?.blockers.joined(separator: " ") ?? "it could not be checked.")
                    + " Nothing was started."), adoption: refreshed.adoption)
        }
        guard isApproved(ticket.cwd), observed?.transcriptExists(sessionID: ticket.sessionID) == true else {
            return BridgeResponse(ok: false, error: BridgeError(
                code: .notAdoptable,
                message: "The directory is no longer approved, or the transcript has gone. Nothing was started."),
                adoption: refreshed.adoption)
        }

        var chosen = launcher
        if let terminal = request.terminal?.lowercased(), !terminal.isEmpty {
            guard terminal == "ghostty", let visible = visibleLauncher else {
                return BridgeResponse(ok: false, error: BridgeError(
                    code: .clientUnavailable,
                    message: "This host cannot open a \(terminal) tab for the resumed session."),
                    adoption: refreshed.adoption)
            }
            chosen = visible
        }

        lock.lock()
        guard sessions[ticket.sessionID] == nil else {
            lock.unlock()
            return refusal(.notAdoptable, "Session \(ticket.sessionID) became owned meanwhile.")
        }
        guard sessions.count < BridgeProtocol.maximumSessions else {
            lock.unlock()
            return refusal(.limitReached, "This host already owns \(sessions.count) sessions, which is its limit.")
        }
        var state = BridgeSessionState(sessionID: ticket.sessionID, cwd: ticket.cwd,
                                       phase: .accepted, startedAt: now())
        state.adoptedFrom = ticket.requestID
        let session = Session(state: state)
        session.launching = true
        sessions[ticket.sessionID] = session
        lock.unlock()

        let sessionID = ticket.sessionID
        let handle: BridgeClientHandle
        do {
            handle = try chosen.resume(
                sessionID: sessionID, cwd: ticket.cwd, model: request.model,
                onLine: { [weak self] line in self?.receive(line, for: sessionID) },
                onExit: { [weak self] status in self?.clientExited(sessionID, status: status) })
        } catch {
            lock.lock()
            sessions.removeValue(forKey: sessionID)
            adoptions[request.requestID]?.blockers = ["The resumed client could not be started: "
                                                      + error.localizedDescription]
            let adoption = adoptions[request.requestID]?.state
            lock.unlock()
            return BridgeResponse(ok: false, error: BridgeError(
                code: .clientUnavailable,
                message: "Could not resume the conversation: \(error.localizedDescription)"),
                adoption: adoption)
        }

        lock.lock()
        session.launching = false
        session.state.pid = handle.pid
        if let status = session.state.exitStatus {
            // Gone before it could be attached — a conversation Claude could not open, most likely.
            append(.note, to: session, text: "the resumed client exited with status \(status) at once")
            let snapshot = session.state
            // The placeholder goes with it, exactly as the `catch` above does and as `handleStart`
            // does for the same case. Leaving it behind is not cosmetic: `prepareAdoption` checks
            // `sessions[sessionID]` first, so that terminal could never be adopted again — it would
            // be refused as "already adopted" by an adoption that never happened — and the dead
            // entry would hold one of the eight session slots until the app restarted. A client
            // retrying with a bad `model` argument could spend all eight.
            sessions.removeValue(forKey: sessionID)
            adoptions[request.requestID]?.blockers = ["The resumed client exited at once (status \(status))."]
            let adoption = adoptions[request.requestID]?.state
            lock.unlock()
            return BridgeResponse(ok: false, error: BridgeError(
                code: .clientUnavailable, message: "The resumed client exited immediately (status \(status))."),
                session: snapshot, adoption: adoption)
        }
        session.handle = handle
        if let visible = handle as? VisibleClaudeHandle {
            session.state.surface = BridgeSurfaceState(terminal: "ghostty",
                                                       windowID: visible.surface.windowID,
                                                       tabID: visible.surface.tabID,
                                                       terminalID: visible.surface.terminalID,
                                                       open: true)
        }
        append(.started, to: session,
               text: "conversation resumed under Warden by adoption \(request.requestID)"
                   + (handle.pid > 0 ? ", pid \(handle.pid)" : ""))
        adoptions[request.requestID]?.phase = .adopted
        adoptions[request.requestID]?.blockers = []
        adoptions[request.requestID]?.nextStep = "Warden owns this conversation now: send, status, "
            + "events and stop use its session id."
        let snapshot = published(session)
        let adoption = adoptions[request.requestID]?.state
        lock.unlock()
        return BridgeResponse(ok: true, session: snapshot, adoption: adoption)
    }

    private func cancelAdoption(_ request: BridgeRequest.AdoptRequest) -> BridgeResponse {
        lock.lock(); defer { lock.unlock() }
        guard var ticket = adoptions[request.requestID], ticket.sessionID == request.sessionID else {
            return refusal(.notAdoptable, "Nothing was prepared under request \(request.requestID) "
                           + "for that session.")
        }
        guard ticket.phase != .adopted else {
            return refusal(.notAdoptable, "That adoption is complete. Stop the session instead.")
        }
        ticket.phase = .cancelled
        ticket.blockers = []
        ticket.nextStep = ticket.exitRequested
            ? "Cancelled. The original client was asked to exit earlier; nothing further was done."
            : "Cancelled. The session was left exactly as it was."
        adoptions[request.requestID] = ticket
        return BridgeResponse(ok: true, adoption: ticket.state)
    }
}

/// Builds a summary out of evidence only. See `BridgeGroundedSummary`.
public enum GroundedSummary {
    static let excerptLimit = 280
    static let maximumFacts = 12

    public static func build(sessionID: String, row: StatusReport.SessionSummary?,
                             context: SessionContextAnswer?, owned: BridgeSessionState?,
                             now: Date) -> BridgeGroundedSummary {
        var facts: [BridgeGroundedSummary.Fact] = []
        func fact(_ statement: String, _ source: String, _ at: Date? = nil) {
            facts.append(.init(statement: String(statement.prefix(400)), source: source, observedAt: at))
        }
        func excerpt(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            return flat.count > excerptLimit ? String(flat.prefix(excerptLimit)) + "…" : flat
        }

        if let owned {
            fact("Warden owns this session; the last prompt it sent is \(owned.phase.rawValue).",
                 "bridge", owned.lastEventAt)
            if let last = owned.messages.last {
                fact("Message \(last.messageID) is \(last.phase.rawValue).", "bridge",
                     last.completedAt ?? last.acknowledgedAt ?? last.sentAt)
            }
            if let parent = owned.parent, parent.state != "unknown" {
                fact("The client reported itself \(parent.state).", "bridge", parent.observedAt)
            }
            let running = owned.jobs.filter { !$0.stale && !$0.ambient && $0.state == "running" }.count
            if running > 0 { fact("\(running) background job(s) reported running.", "bridge") }
            if owned.attention?.open == true {
                fact("It handed work back for you to test or review.", "bridge", owned.attention?.raisedAt)
            }
        }
        let rowAt = row.map { now.addingTimeInterval(-Double($0.lastEventAgeSeconds)) }
        if let row {
            fact("The queue has it as \(row.state), attention \(row.attention).", "queue", rowAt)
            if let background = row.background, background.running > 0 {
                fact(background.summary, "queue", background.observedAt)
            }
            fact("Its Claude process is \(row.process).", "process")
        }
        if let context {
            if context.attention.certainty == "waiting", let reason = context.attention.reason {
                fact("It is waiting on you: \(excerpt(reason)).", "queue")
            }
            if let read = context.context, read.availability == .read {
                if let request = read.latestUserRequest {
                    fact("Last request: “\(excerpt(request.excerpt))”", "transcript", request.at)
                }
                if let reply = read.latestAssistantResponse {
                    fact("Last reply: “\(excerpt(reply.excerpt))”", "transcript", reply.at)
                }
                for question in read.questions.suffix(2) where question.answered == "notObserved" {
                    fact("It asked: “\(excerpt(question.question))” — no answer seen.", "transcript",
                         question.askedAt)
                }
            }
        }

        let name = row?.displayName ?? context?.displayName
            ?? owned.map { ($0.cwd as NSString).lastPathComponent } ?? "This session"
        let headline: String
        if let owned, owned.phase == .active || owned.phase == .clientAcknowledged {
            headline = "\(name) is working on a prompt Warden sent."
        } else if let owned, [.completed, .failed, .uncertain, .stopped, .stopping].contains(owned.phase) {
            headline = "\(name): its last Warden prompt is \(owned.phase.rawValue)."
        } else if let row {
            switch (row.attention, row.state) {
            case ("waiting", _):
                headline = "\(name) is waiting for you"
                    + (context?.attention.reason.map { ": \(excerpt($0))." } ?? ".")
            case (_, "working"): headline = "\(name) is working."
            case (_, "backgroundWaiting"): headline = "\(name) is waiting on its own background work."
            case ("uncertain", _): headline = "\(name) ended a turn; whether it needs you is unknown."
            case ("awaitingFirstHook", _): headline = "\(name) is running but has not reported yet."
            case (_, "ended"): headline = "\(name) has ended."
            default: headline = "\(name) is \(row.state)."
            }
        } else {
            headline = "\(name) is owned by Warden; nothing else is known."
        }

        var caveats: [String] = []
        for caveat in context?.attention.caveats ?? [] where !caveats.contains(caveat) {
            caveats.append(caveat)
        }
        return BridgeGroundedSummary(sessionID: sessionID, displayName: row?.displayName ?? context?.displayName,
                                     headline: headline, facts: Array(facts.prefix(maximumFacts)),
                                     caveats: Array(caveats.prefix(5)), generatedAt: now)
    }
}
