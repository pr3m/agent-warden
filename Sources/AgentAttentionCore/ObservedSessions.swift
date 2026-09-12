import Foundation

/// What the bridge may know about one session Warden observes in a terminal.
public struct ObservedSessionRecord: Sendable, Equatable {
    public var sessionID: String
    public var cwd: String
    public var displayName: String?
    /// The Claude process the hooks identified, pinned by start time. Nil means unidentified — and
    /// an unidentified process cannot be proven to have gone, so it cannot be adopted.
    public var pid: Int32?
    public var pidStartedAt: Double?
    public var tty: String?
    /// `working`, `awaitingUser`, `backgroundWaiting`, … — the queue's own word.
    public var activity: String
    /// Background jobs the last `Stop` said were still running.
    public var backgroundRunning: Int

    public init(sessionID: String, cwd: String, displayName: String? = nil, pid: Int32?,
                pidStartedAt: Double?, tty: String? = nil, activity: String,
                backgroundRunning: Int = 0) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.displayName = displayName
        self.pid = pid
        self.pidStartedAt = pidStartedAt
        self.tty = tty
        self.activity = activity
        self.backgroundRunning = backgroundRunning
    }
}

/// The observed half of a `sessions` answer: `aa-status`'s rows, and whether to believe them.
public struct ObservedRows: Sendable, Equatable {
    public var sessions: [StatusReport.SessionSummary]
    public var trustworthy: Bool
    public var warnings: [String]

    public init(sessions: [StatusReport.SessionSummary], trustworthy: Bool, warnings: [String] = []) {
        self.sessions = sessions
        self.trustworthy = trustworthy
        self.warnings = warnings
    }
}

/// A live process holding a conversation, as Claude Code's own registry reports it.
public struct ObservedHolder: Sendable, Equatable {
    public var pid: Int32
    public var startedAt: Double?

    public init(pid: Int32, startedAt: Double?) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// Everything the bridge reads, or checks, about sessions it does not own. A seam: the rules in
/// the host are tested against a fake, and the real one below reads the same files `aa-status`
/// does.
public protocol ObservedSessionSource: Sendable {
    /// The same rows `aa-status --json` prints.
    func rows() -> ObservedRows
    func record(sessionID: String) -> ObservedSessionRecord?
    /// Identity first, contents second — `SessionContextQuery`, unchanged.
    func context(sessionID: String) -> SessionContextAnswer
    func transcriptExists(sessionID: String) -> Bool
    /// Live processes holding this conversation, other than the ones named, and other than the
    /// clients this host runs in its own relays. **Nil means it could not be checked**, which is
    /// never read as "nobody".
    func foreignHolders(sessionID: String, excluding pids: Set<Int32>) -> [ObservedHolder]?
    /// Is that exact process — pid and start time — still running?
    func processState(pid: Int32, startedAt: Double) -> LivenessVerdict
    /// Ask one process to exit, after checking again that it is the same Claude process. False
    /// means nothing was signalled.
    func requestExit(pid: Int32, startedAt: Double) -> Bool
    /// Bring the tab the user linked to this session forward, through the app that made the link.
    func focus(sessionID: String) -> BridgeResponse
}

/// The real source: Warden's saved queue, Claude Code's registry and transcripts, the process
/// table, and the app for anything that needs a window server.
public struct WardenObservedSessions: ObservedSessionSource {
    public let paths: AppPaths
    public let claudeHome: URL
    /// The relay this host runs visible sessions through. A Claude process under it is one of ours.
    public let relayExecutable: String?
    public let appControlSocket: String

    public init(paths: AppPaths, claudeHome: URL = SessionRegistry.defaultRoot(),
                relayExecutable: String?, appControlSocket: String) {
        self.paths = paths
        self.claudeHome = claudeHome
        self.relayExecutable = relayExecutable
        self.appControlSocket = appControlSocket
    }

    private var store: EventStore { EventStore(paths: paths) }
    private var config: AttentionConfig { AttentionConfig.load(from: paths.configFile) }

    private func report() -> StatusReport {
        // The same call `aa-status` makes. There is no window server here, so a link's verdict is
        // "could not check" — never rounded up to valid.
        StatusReport.build(store: store, config: config,
                           pairings: PairingStore(url: paths.pairingsFile).load())
    }

    public func rows() -> ObservedRows {
        let report = report()
        return ObservedRows(sessions: report.sessions, trustworthy: report.answerIsTrustworthy,
                            warnings: report.warnings)
    }

    public func record(sessionID: String) -> ObservedSessionRecord? {
        guard let state = store.loadSnapshot()?.sessions[sessionID] else { return nil }
        let row = report().sessions.first { $0.sessionID == sessionID }
        return ObservedSessionRecord(
            sessionID: sessionID, cwd: state.identity.cwd, displayName: row?.displayName,
            pid: state.identity.claudePID, pidStartedAt: state.identity.claudePIDStartedAt,
            tty: state.identity.tty, activity: state.activity.rawValue,
            backgroundRunning: row?.background?.running ?? 0)
    }

    public func context(sessionID: String) -> SessionContextAnswer {
        SessionContextQuery.run(sessionID: sessionID, store: store, config: config,
                                claudeHome: claudeHome)
    }

    public func transcriptExists(sessionID: String) -> Bool {
        if case .success = SessionContextReader.locateTranscript(sessionID: sessionID,
                                                                  claudeHome: claudeHome) {
            return true
        }
        return false
    }

    public func foreignHolders(sessionID: String, excluding pids: Set<Int32>) -> [ObservedHolder]? {
        let scan = SessionRegistry.scan(root: claudeHome)
        // Only a scan that could look and verify is evidence of absence.
        guard scan.isAuthoritative, !scan.unverifiableSessionIDs.contains(sessionID) else { return nil }
        return scan.verified
            .filter { $0.record.sessionID == sessionID && !pids.contains($0.record.pid) }
            .filter { !runsUnderOwnRelay($0.record.pid) }
            .map { ObservedHolder(pid: $0.record.pid, startedAt: $0.identity.claudePIDStartedAt) }
    }

    private func runsUnderOwnRelay(_ pid: Int32) -> Bool {
        guard let relayExecutable else { return false }
        let relay = URL(fileURLWithPath: relayExecutable).resolvingSymlinksInPath().path
        return ProcessProbe.ancestry(of: pid).dropFirst().contains { ancestor in
            ProcessProbe.executablePath(pid: ancestor.pid)
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == relay } ?? false
        }
    }

    public func processState(pid: Int32, startedAt: Double) -> LivenessVerdict {
        SystemLiveness().probe(pid: pid, startedAt: startedAt)
    }

    public func requestExit(pid: Int32, startedAt: Double) -> Bool {
        // Checked again here, at the last moment: the same pid, born at the same time, running a
        // Claude executable. Anything less and a recycled pid could be somebody else's process.
        guard pid > 1, pid != getpid(), let snapshot = ProcessProbe.snapshot(pid: pid),
              abs(snapshot.startedAt - startedAt) <= SessionRegistry.startTimeTolerance,
              ProcessProbe.looksLikeClaude(command: snapshot.command,
                                           executablePath: ProcessProbe.executablePath(pid: pid))
        else { return false }
        // One polite signal to one process. Never its group, never SIGKILL: a client that will not
        // leave stays where it is, and the adoption says so.
        return kill(pid, SIGTERM) == 0
    }

    public func focus(sessionID: String) -> BridgeResponse {
        (try? BridgeSocketClient.send(.focus(sessionID: sessionID), to: appControlSocket, timeout: 20))
            ?? BridgeResponse(ok: false, error: BridgeError(
                code: .clientUnavailable,
                message: "Exact-tab focus is done by the Agent Warden app, and it did not answer. "
                    + "Is it running? Nothing was focused."))
    }
}
