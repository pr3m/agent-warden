import AppKit
import AgentAttentionCore

/// Is another Agent Warden already running?
///
/// Asked of the system rather than of a file. A pid file records what *was* true when it was
/// written; `NSRunningApplication` answers what is true now, and a stale record cannot make a fresh
/// launch refuse to start.
enum SingleInstance {
    /// The pid of another running Agent Warden, or nil when this is the only one.
    ///
    /// "Another" is decided by bundle identity and by pid — never by executable path. The app can be
    /// installed in one place and running from another after an upgrade, and two copies of the same
    /// warden are still two wardens over one data directory.
    static func otherRunningWarden(bundleID: String? = Bundle.main.bundleIdentifier,
                                   mine: Int32 = ProcessInfo.processInfo.processIdentifier) -> Int32? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
            .first { $0 != mine }
    }
}
