import Foundation
import AgentAttentionCore

/// Runs the registry scan and the transcript reads off the main thread.
///
/// Discovery touches the filesystem: a directory listing, a handful of small JSON files, and a
/// bounded tail read per session. None of that belongs on the thread drawing the bubble, so it all
/// happens on a utility queue and only the finished report crosses back.
///
/// It is also rate-limited. Sessions do not appear and vanish by the second, and re-reading
/// transcript tails in a tight loop would be the one part of this app that could be felt.
final class DiscoveryService {
    /// Called on the main queue with a completed scan.
    var onReport: ((DiscoveryReport) -> Void)?

    private let claudeHome: URL
    private let queue = DispatchQueue(label: "dev.agentwarden.discovery", qos: .utility)
    private var inFlight = false
    private var lastScan: Date = .distantPast

    /// Long enough that it is never in the way, short enough that a session opened a moment ago
    /// shows up while you are still looking for it.
    private let interval: TimeInterval = 20

    init(claudeHome: URL = SessionRegistry.defaultRoot()) {
        self.claudeHome = claudeHome
    }

    /// Scan unless one is already running or the last one was recent. `force` for launch.
    func scan(force: Bool = false) {
        let now = Date()
        guard !inFlight, force || now.timeIntervalSince(lastScan) >= interval else { return }
        inFlight = true
        lastScan = now

        let home = claudeHome
        queue.async { [weak self] in
            let report = DiscoveryService.perform(claudeHome: home)
            DispatchQueue.main.async {
                self?.inFlight = false
                self?.onReport?(report)
            }
        }
    }

    /// The whole of the work, off the main thread.
    static func perform(claudeHome: URL) -> DiscoveryReport {
        var report = SessionRegistry.scan(root: claudeHome)
        guard !report.verified.isEmpty else { return report }

        // The registry knows where each session was launched; the transcript's last line knows
        // where it is working now. Reading a bounded tail is what turns "atlas" into the worktree
        // the session actually sits in.
        let projects = claudeHome.appendingPathComponent("projects", isDirectory: true)
        report.verified = report.verified.map { found in
            guard let transcript = TranscriptMetadata.locate(
                sessionID: found.record.sessionID,
                cwd: found.record.cwd,
                projectsRoot: projects
            ) else { return found }
            let summary = TranscriptMetadata.tail(of: transcript, expecting: found.record.sessionID)
            return found.enriched(withTranscript: summary)
        }
        return report
    }
}
