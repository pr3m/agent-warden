import Foundation
import AgentAttentionCore

/// Keeps each session's branch reading current, off the main thread.
///
/// The transcript stamps `gitBranch` when a session starts and never revisits it. Five live sessions
/// on this machine were therefore all labelled `main` while their working directories were on
/// `cs/client-info-t1`, `cs/red645-own-capital` and so on. Reading the directory is the only way to
/// know, so that is what this does — and it does it under the same rules as everything else here:
/// read-only, bounded, and honest about failure.
///
/// - `git branch --show-current` and nothing else. No fetch, no index, no lock, no network.
/// - One probe at a time, on a serial background queue. The main thread never waits for `git`.
/// - Rate-limited per session: a directory is re-read at most once a minute.
/// - Every outcome is reported, including the ones that are not a branch. `detached`,
///   `notARepository`, `denied` and `timedOut` are shown as themselves, never as a name.
final class BranchService {
    /// Applied on the main thread.
    var onReading: ((BranchFact, String) -> Void)?

    /// How long a reading stays current before the directory is read again.
    let staleAfter: TimeInterval = 60
    private let queue = DispatchQueue(label: "ai.wundamental.agent-warden.branch", qos: .utility)
    private var inFlight: Set<String> = []
    private let probe: (String) -> BranchFact

    init(probe: @escaping (String) -> BranchFact = { GitBranchProbe.read(directory: $0) }) {
        self.probe = probe
    }

    /// Ask for readings for whichever sessions need one. Returns immediately.
    ///
    /// A session already being probed is skipped, so a slow repository cannot queue up behind
    /// itself on every sweep.
    func refresh(sessions: [SessionState], now: Date = Date(), limit: Int = 6) {
        let wanted = sessions.prefix(limit).filter { !inFlight.contains($0.identity.sessionID) }
        for session in wanted {
            let id = session.identity.sessionID
            let path = session.identity.cwd
            guard !path.isEmpty else { continue }
            inFlight.insert(id)
            queue.async { [weak self] in
                guard let self else { return }
                let fact = self.probe(path)
                DispatchQueue.main.async {
                    self.inFlight.remove(id)
                    self.onReading?(fact, id)
                }
            }
        }
    }

    var debugInFlightCount: Int { inFlight.count }
}
