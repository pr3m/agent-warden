import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Every path the app touches, rooted at one directory.
///
/// `AGENT_ATTENTION_HOME` overrides the root. Tests always set it, so a test run can never read or
/// write the real session store, and the hook emitter can be exercised in a sandbox.
public struct AppPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let environmentKey = "AGENT_ATTENTION_HOME"

    public static func resolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let override = environment[environmentKey], !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        return AppPaths(root: defaultRoot)
    }

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AgentAttention", isDirectory: true)
    }

    /// Attention/lifecycle events dropped by the hook emitter, consumed by the app.
    public var spool: URL { root.appendingPathComponent("spool", isDirectory: true) }
    /// Files that failed to parse, kept for debugging instead of silently deleted.
    public var quarantine: URL { root.appendingPathComponent("quarantine", isDirectory: true) }
    /// One file per live session, overwritten on every hook. Doubles as the heartbeat.
    public var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var stateFile: URL { root.appendingPathComponent("state.json") }
    public var configFile: URL { root.appendingPathComponent("config.json") }
    public var logFile: URL { root.appendingPathComponent("agent-warden.log") }
    /// The user's confirmed session ↔ terminal-tab links. A file of its own, so a queue migration
    /// or a corrupt `state.json` can never take a decision the user made with them.
    public var pairingsFile: URL { root.appendingPathComponent("pairings.json") }
    /// Written by the running app so a read-only query can tell "nothing is waiting" from
    /// "nothing is watching".
    public var appStatusFile: URL { root.appendingPathComponent("app.json") }
    public var installManifest: URL { root.appendingPathComponent("install-manifest.json") }
    /// Roam's own state. Warden's data directory, never `~/.claude/roam` — roam here is
    /// independent of the plugin it replaces.
    public var roamFile: URL { root.appendingPathComponent("roam.json") }

    /// 0700: this directory records which projects you are working on and when. It is nobody
    /// else's business on a shared machine.
    public func createDirectories() throws {
        let fm = FileManager.default
        for dir in [root, spool, quarantine, sessions] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } else {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }
        }
    }
}

/// Write-to-temp-then-rename. A half-written state file after a crash or a kill would be worse
/// than no state file at all.
public enum AtomicFile {
    public enum Failure: Error, CustomStringConvertible {
        case renameFailed(String, Int32)
        public var description: String {
            switch self {
            case let .renameFailed(path, code): return "could not replace \(path): errno \(code)"
            }
        }
    }

    /// `rename(2)` rather than `FileManager.replaceItemAt`: it is atomic, and unlike
    /// `replaceItemAt` it works when the destination does not exist yet, which is every file on
    /// the very first run.
    public static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        // The temp name carries a uuid, so two writers never collide on it.
        let temp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: .atomic)
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            guard rename(temp.path, url.path) == 0 else {
                let code = errno
                try? fm.removeItem(at: temp)
                throw Failure.renameFailed(url.path, code)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}

public enum JSONCoding {
    /// ISO-8601 with milliseconds.
    ///
    /// Sub-second precision is not cosmetic: a `PostToolUse` that answers an `AskUserQuestion`
    /// often lands in the same second as the ask, and ordering decides whether the card clears or
    /// sticks. `.iso8601` truncates to whole seconds and loses exactly that.
    public static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return f
    }()

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .formatted(dateFormatter)
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .formatted(dateFormatter)
        return d
    }
}
