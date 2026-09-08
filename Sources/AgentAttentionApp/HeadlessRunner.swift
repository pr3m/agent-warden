import Foundation
import AgentAttentionCore

/// Runs one pass of the app's refresh loop and prints the attention queue as text.
///
/// Exists so the whole pipeline — real `aa-emit` binary, real files, real engine — can be
/// exercised and inspected from a shell, with no window server and no clicking.
/// `Scripts/smoke-test.sh` uses it; so can anyone debugging a live install.
///
/// Unlike `aa-status`, this one *does* mutate: it drains, sweeps and saves, exactly as the running
/// app would. Do not run it while the app is running.
enum HeadlessRunner {
    static func run(cycles: Int) -> Int32 {
        let paths = AppPaths.resolved()
        try? paths.createDirectories()
        let store = EventStore(paths: paths)
        let config = AttentionConfig.load(from: paths.configFile)
        let engine = AttentionEngine(
            config: config,
            clock: SystemClock(),
            liveness: SystemLiveness(),
            restoring: store.loadSnapshot()
        )

        var effects: [EngineEffect] = []
        for _ in 0..<max(1, cycles) {
            let orphans = store.pruneHeartbeats(now: Date(), staleAfter: config.staleSessionSeconds, liveness: SystemLiveness())
            if !orphans.isEmpty {
                print("pruned orphaned session records: \(orphans.count)")
            }

            let drained = store.readSpool()
            if !drained.quarantined.isEmpty {
                print("quarantined: \(drained.quarantined.joined(separator: ", "))")
            }

            var pass = engine.ingest(drained.events)
            pass += engine.applyHeartbeats(store.readHeartbeats())
            pass += engine.sweep()
            effects += pass

            // Same durability rule as the app: the spool files go only after the state that
            // absorbed them is on disk.
            do {
                try store.save(snapshot: engine.snapshot())
                store.acknowledge(drained.receipts)
            } catch {
                print("could not save state; keeping \(drained.receipts.count) spool file(s): \(error)")
            }

            for case let .sessionDropped(sessionID, _) in pass {
                store.removeHeartbeat(sessionID: sessionID)
            }
        }

        // Same read-only registry scan the app runs, so the whole path can be exercised from a
        // shell. `AGENT_WARDEN_CLAUDE_HOME` points it at a fixture in tests.
        let claudeHome = SessionRegistry.defaultRoot()
        let discovery = DiscoveryService.perform(claudeHome: claudeHome)
        let added = engine.apply(discovery: discovery, at: Date())
        try? store.save(snapshot: engine.snapshot())
        print("registry: present=\(discovery.registryPresent) considered=\(discovery.filesConsidered) "
              + "verified=\(discovery.verified.count) rejected=\(discovery.rejected.count) "
              + "malformed=\(discovery.malformed) newlyDiscovered=\(added)")
        for rejected in discovery.rejected {
            print("  rejected \(String(rejected.sessionID.prefix(8))) pid=\(rejected.pid): \(rejected.verdict.rawValue)")
        }

        // The branch each session is actually on, read from its own directory. The transcript's
        // value is stamped at launch and goes stale the moment a session moves into a worktree.
        for (id, session) in engine.sessions.sorted(by: { $0.key < $1.key }) {
            guard !session.identity.cwd.isEmpty else { continue }
            engine.apply(branch: GitBranchProbe.read(directory: session.identity.cwd), sessionID: id)
        }
        try? store.save(snapshot: engine.snapshot())

        // Links for sessions that have ended are retired here too, so this path is the same one the
        // running app takes. It touches only the link file — never the queue.
        let pairings = PairingStore(url: paths.pairingsFile)
        if let retired = try? pairings.retire(keeping: Set(engine.sessions.keys)), retired > 0 {
            print("retired terminal link(s): \(retired)")
        }

        print("root: \(paths.root.path)")
        print("sessions tracked: \(engine.sessions.count)")
        for (id, session) in engine.sessions.sorted(by: { $0.key < $1.key }) {
            let plan = TerminalTarget.plan(for: session.identity)
            print("  session \(String(id.prefix(8))) \(session.identity.projectName) "
                  + "state=\(session.activity.rawValue) pid=\(session.identity.claudePID.map(String.init) ?? "-") "
                  + "terminal=\(session.identity.terminalName) click=\(plan.confidence.rawValue) "
                  + "hookCoverage=\(session.hasHookEvidence) "
                  + "background=\(session.background?.availability.rawValue ?? "unseen") "
                  // A reading that succeeded prints its own answer and where it came from; one that
                  // failed prints why it failed. Neither is ever shown as a branch name.
                  + "branch=\(session.identity.branchFact.map { "\($0.branch ?? $0.state)/\($0.source)" } ?? session.identity.branchAvailability) "
                  + "link=\(pairings.pairing(for: id).map { "\($0.terminalID)/\($0.provenance)" } ?? "-")")
        }

        // Reported separately from `pending` on purpose: a session paused on work it started is not
        // asking for anything.
        let onBackground = engine.sessionsWaitingOnBackgroundWork(at: Date())
        print("waiting on background work: \(onBackground.count)")
        for session in onBackground {
            print("  \(session.identity.projectName) — \(session.background?.summaryLine ?? "paused")")
        }

        print("pending: \(engine.pendingCount) (snoozed \(engine.snoozedCount))")
        for item in engine.visibleItems() {
            print("  [\(item.kind.rawValue)] \(item.identity.projectName) — \(item.detail) "
                  + "(\(item.source.rawValue), seen \(item.occurrences)x)")
        }

        let surviving = Set(engine.visibleItems().map(\.id))
        for effect in effects {
            switch effect {
            case .raised(let item):
                print("effect: raised \(item.kind.rawValue) for \(item.identity.projectName)"
                      + (surviving.contains(item.id) ? "" : " (resolved before it could be shown)"))
            case .repeated(let item): print("effect: repeated \(item.kind.rawValue) for \(item.identity.projectName)")
            case .unsnoozed(let item): print("effect: unsnoozed \(item.kind.rawValue) for \(item.identity.projectName)")
            case .resolved(_, let reason): print("effect: resolved (\(reason.rawValue))")
            case .sessionDropped(let id, let reason): print("effect: dropped session \(String(id.prefix(8))) (\(reason.rawValue))")
            }
        }
        return 0
    }
}
