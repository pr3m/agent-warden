import Foundation
import AgentAttentionCore

/// Links sessions to their Ghostty tabs without anybody being asked to point at one.
///
/// Linking was manual because a name or a working directory cannot tell four tabs in one repository
/// apart, and a wrong link sends somebody to a stranger's session with full confidence. `TabHandshake`
/// removes that problem — the terminal identifies *itself* — so this is the part that decides when to
/// ask the question, and when to leave a session alone.
///
/// The rules it holds to, all for the same reason: this writes a title to somebody's terminal.
///
/// - **Only sessions that need one.** Already linked, no tty, or not a Ghostty session: skipped.
/// - **One at a time, one per tick.** The handshake takes the process-wide script gate and briefly
///   changes a title. Doing several at once would flicker a row of tabs and starve the gate.
/// - **It gives up on a session rather than retrying for ever.** A session in tmux, in another
///   terminal, or in no terminal at all will never answer, and asking it every few seconds would
///   rewrite its title for the life of the app. Three attempts, then it is left alone until it is
///   heard from as a new session.
/// - **Nothing is guessed.** A session that does not answer stays unlinked, exactly as before, and
///   the user can still link it by hand.
final class TabAutoLinker {
    /// How many times one session is asked before it is left alone.
    static let maximumAttempts = 3

    private let ghostty: GhosttyControlling
    private let titles: TerminalTitleWriting
    private let pairings: PairingStore
    private let log: (String) -> Void

    private let lock = NSLock()
    private var attempts: [String: Int] = [:]
    private var running = false

    init(ghostty: GhosttyControlling,
         titles: TerminalTitleWriting = OSCTitleWriter(),
         pairings: PairingStore,
         log: @escaping (String) -> Void = { _ in }) {
        self.ghostty = ghostty
        self.titles = titles
        self.pairings = pairings
        self.log = log
    }

    /// Which session, if any, is worth asking on this tick.
    ///
    /// Pure, and separated from the doing, so the policy can be exercised without a terminal.
    static func nextCandidate(sessions: [SessionIdentity],
                              linked: Set<String>,
                              attempts: [String: Int]) -> SessionIdentity? {
        sessions.first { session in
            guard !linked.contains(session.sessionID) else { return false }
            guard let tty = session.tty, !tty.isEmpty, tty != "-" else { return false }
            // Under tmux the tty is the pane's, not the tab's, so a handshake there would rename a
            // tab that has nothing to do with this session. Left alone entirely.
            guard session.tmuxPane == nil, session.tmuxSocket == nil else { return false }
            guard (session.termProgram ?? "").lowercased() == "ghostty" else { return false }
            return (attempts[session.sessionID] ?? 0) < TabAutoLinker.maximumAttempts
        }
    }

    /// Ask one session's terminal to identify itself. Returns whether a new link was saved.
    ///
    /// Called off the main thread: it takes the script gate and waits on a terminal.
    @discardableResult
    func linkOne(among sessions: [SessionIdentity]) -> Bool {
        lock.lock()
        if running { lock.unlock(); return false }        // never two handshakes at once
        running = true
        let seen = attempts
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }

        let linked = Set(pairings.load().keys)
        guard let session = TabAutoLinker.nextCandidate(sessions: sessions, linked: linked,
                                                        attempts: seen) else { return false }

        lock.lock(); attempts[session.sessionID, default: 0] += 1; lock.unlock()

        guard let terminalApp = ghostty.processIdentity() else { return false }
        let ghostty = self.ghostty
        let handshake = TabHandshake(titles: titles, readAll: { ghostty.readAllTerminals() })

        switch handshake.identifyTerminal(onTTY: session.tty) {
        case .failure(let failure):
            // Said once per session, not once per tick: a session that is not in Ghostty is an
            // ordinary state, not a fault, and it must not fill a log.
            if (seen[session.sessionID] ?? 0) == 0 {
                log("no tab answered for \(session.sessionID.prefix(8)) (\(failure)); it stays unlinked")
            }
            return false
        case .success(let terminal):
            // The identity's own recorded start time, so the link is pinned to the same incarnation
            // the rest of the app is talking about rather than to whatever holds that pid now.
            guard let pid = session.claudePID,
                  let started = session.claudePIDStartedAt
                      ?? ProcessProbe.snapshot(pid: pid)?.startedAt else { return false }
            let pairing = TerminalPairing(
                sessionID: session.sessionID,
                claudePID: pid,
                claudePIDStartedAt: started,
                tty: session.tty,
                terminalAppBundleID: GhosttyAdapter.bundleIdentifier,
                terminalAppPID: terminalApp.pid,
                terminalAppStartedAt: terminalApp.startedAt,
                terminalID: terminal.terminalID,
                tabID: terminal.tabID,
                windowID: terminal.windowID,
                terminalName: terminal.name,
                workingDirectory: terminal.workingDirectory,
                pairedAt: Date(),
                // Nil for the same reason a confirmed link leaves it nil: this is the terminal
                // saying which one it is, not us navigating there and reading back that it landed.
                lastVerifiedAt: nil,
                // Distinct from `userConfirmed` on purpose. Both are evidence, and they are not the
                // same evidence — one is a person pointing, the other is a terminal answering.
                provenance: "derivedHandshake"
            )
            do {
                try pairings.put(pairing)
                log("linked \(session.sessionID.prefix(8)) to tab \(terminal.name ?? terminal.terminalID)")
                return true
            } catch {
                log("could not save the link for \(session.sessionID.prefix(8)): \(error)")
                return false
            }
        }
    }

    /// A session heard from afresh gets its attempts back — it may have moved into a terminal.
    func forget(sessionID: String) {
        lock.lock(); attempts[sessionID] = nil; lock.unlock()
    }
}
