import Foundation

/// What the bridge may do on this machine, in a file of its own: `<home>/bridge.json`.
///
/// Kept apart from `config.json` on purpose. The app rewrites `config.json` whenever a setting
/// changes; this file is **only ever written by the user**, so nothing Agent Warden does can widen
/// the directories a session may be started or adopted in. A missing file means the bridge runs
/// with no approved directory at all — it can list, read and focus, and it can start nothing.
///
/// ```json
/// { "enabled": true, "approvedRoots": ["~/dev/atlas", "~/dev/orbit-api"] }
/// ```
public struct BridgeSettings: Codable, Sendable, Equatable {
    /// Should the app run a bridge host while it runs? On unless the user says otherwise.
    public var enabled: Bool
    /// Project directories a session may be started or adopted in, and nothing above them.
    public var approvedRoots: [String]

    public static let `default` = BridgeSettings(enabled: true, approvedRoots: [])

    public init(enabled: Bool, approvedRoots: [String]) {
        self.enabled = enabled
        self.approvedRoots = approvedRoots
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Absent means "not configured", which stays on. *Present and unreadable* is different: it
        // is somebody trying to say something about this setting. `{"enabled": "false"}` and
        // `{"enabled": 0}` both used to turn the bridge on, which is the one direction this
        // particular key must never fail in.
        if c.contains(.enabled) {
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        } else {
            enabled = true
        }
        approvedRoots = ((try? c.decodeIfPresent([String].self, forKey: .approvedRoots)) ?? nil) ?? []
    }

    /// Read fresh, every time. A file that will not parse grants nothing but still lets the bridge
    /// run, so a typo costs the ability to start sessions rather than the whole bridge.
    public static func load(from url: URL) -> BridgeSettings {
        guard let data = try? Data(contentsOf: url) else { return .default }
        guard let settings = try? JSONCoding.decoder.decode(BridgeSettings.self, from: data) else {
            return BridgeSettings(enabled: true, approvedRoots: [])
        }
        return settings
    }

    /// Resolved roots that are narrow enough to mean "this project".
    ///
    /// An approval of `/`, of the home directory, or of anything that contains it is not a list of
    /// projects — it is every project, every dotfile and every other repository on the machine,
    /// and it is refused rather than honoured. So are the shared system trees. The same rule runs
    /// on command-line approvals and on the settings file.
    public static func acceptableRoots(_ roots: [String],
                                       home: String = NSHomeDirectory()) -> [String] {
        let resolvedHome = BridgeHost.normalise(home)
        return roots.map { BridgeHost.normalise($0) }.filter { isAcceptableRoot($0, home: resolvedHome) }
    }

    static let tooBroad: Set<String> = [
        "/", "/Users", "/private", "/private/tmp", "/private/var", "/tmp", "/var", "/Volumes",
        "/System", "/Library", "/Applications", "/opt", "/usr", "/etc",
    ]

    static func isAcceptableRoot(_ resolved: String, home: String) -> Bool {
        guard resolved.hasPrefix("/"), !tooBroad.contains(resolved) else { return false }
        // The home directory itself, or anything above it.
        let withSlash = resolved.hasSuffix("/") ? resolved : resolved + "/"
        return resolved != home && !home.hasPrefix(withSlash)
    }
}

/// Where the bridge's files live. One place, so the app, the host and the adapter cannot disagree.
public extension AppPaths {
    var bridgeSocket: URL { root.appendingPathComponent("bridge.sock") }
    /// The app's own endpoint, for the one thing only it can do: focus a linked tab.
    var appControlSocket: URL { root.appendingPathComponent("app-control.sock") }
    var bridgeSettingsFile: URL { root.appendingPathComponent("bridge.json") }
    var bridgeAuditLog: URL { root.appendingPathComponent("bridge-audit.jsonl") }
}
