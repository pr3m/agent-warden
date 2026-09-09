import Foundation

/// The protocol version the two ends must agree on. Bumped whenever a verb or a reply
/// changes shape, so an upgraded app and a stale daemon fail loudly at `hello` rather
/// than subtly at `acquire`.
public enum PowerProtocolVersion {
    public static let current = 1
}

public enum PowerError: String, Sendable, Equatable {
    /// Another connection already holds the lease.
    case busy
    /// `SleepDisabled` was already set by something that is not us. We never take it over.
    case foreign
    /// This connection does not hold the lease it is trying to renew or release.
    case nolease
    /// Protocol version mismatch.
    case version
    /// An unparseable line.
    case unknown
    /// `pmset` returned success but the read-back did not show the expected transition.
    case unverified
    /// `pmset` itself failed to run or exited non-zero.
    case pmsetFailed
    /// The app's own idle-sleep assertion could not be taken. Distinct from a daemon
    /// failure on purpose: reporting an app-side failure as a `pmset` failure would send
    /// someone debugging the daemon over a problem that is not there.
    case assertionFailed
}

/// `PowerError` is a wire vocabulary first — the daemon carries these as replies rather than
/// throwing them, which is why the enum itself declares only `String, Sendable, Equatable`.
///
/// The conformance lives here, next to the type, because it is a property of the type and not
/// of any one consumer. Every client that presents `Result<Void, PowerError>` needs it, and a
/// retroactive conformance declared in one client would have to be duplicated by the next —
/// two conformances for one type being exactly the situation to avoid.
extension PowerError: Error {}

/// What the app may ask the root daemon to do. Deliberately five verbs and no arguments
/// beyond a version integer: the daemon runs as root, and every byte it accepts from a
/// socket is attack surface. Nothing here is ever interpolated into a command.
public enum PowerRequest: Sendable, Equatable {
    case hello(version: Int)
    case acquire
    case renew
    case release
    case status

    public var wire: String {
        switch self {
        case .hello(let version): return "hello \(version)"
        case .acquire: return "acquire"
        case .renew: return "renew"
        case .release: return "release"
        case .status: return "status"
        }
    }

    public static func parse(_ line: String) -> PowerRequest? {
        // A control character means this is not a line we wrote. Refuse before splitting.
        guard !line.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        switch fields.count {
        case 1:
            switch fields[0] {
            case "acquire": return .acquire
            case "renew": return .renew
            case "release": return .release
            case "status": return .status
            default: return nil
            }
        case 2:
            guard fields[0] == "hello", let version = Int(fields[1]), version > 0 else { return nil }
            return .hello(version: version)
        default:
            return nil
        }
    }
}

/// What the daemon sends back to the app in response to a request. The daemon reports
/// what it actually observes, not what it intended: `SleepDisabled` carries the *read-back*
/// of the power setting from `pmset`, not a bool that says "we tried to set it". This
/// asymmetry is deliberate — the app cannot trust its own writes.
///
/// `parse` does not guard against control characters (unlike `PowerRequest.parse`),
/// but this is safe: every accept path requires an exact field match (`ok`, `held`, `free`,
/// `error`) followed by optional Int or rawValue parsing. A control character in the line
/// breaks both the field match and any Int/rawValue conversion, so the input is rejected
/// before any case succeeds.
public enum PowerReply: Sendable, Equatable {
    /// The daemon accepted the request and has nothing more to report.
    case ok
    /// The daemon accepted the request and is reporting its protocol version.
    case okVersion(Int)
    /// The daemon holds the lease; the app will lose it after this many seconds.
    /// The read-back value shows what `pmset` actually recorded.
    case held(secondsRemaining: Int, setting: SleepDisabled)
    /// The daemon does not hold the lease; this is the current machine-wide setting.
    case free(setting: SleepDisabled)
    /// The request failed; the daemon is reporting why.
    case error(PowerError)

    public var wire: String {
        switch self {
        case .ok: return "ok"
        case .okVersion(let version): return "ok \(version)"
        case .held(let seconds, let setting): return "held \(seconds) \(setting.rawValue)"
        case .free(let setting): return "free \(setting.rawValue)"
        case .error(let error): return "error \(error.rawValue)"
        }
    }

    public static func parse(_ line: String) -> PowerReply? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let head = fields.first else { return nil }
        switch (head, fields.count) {
        case ("ok", 1): return .ok
        case ("ok", 2): return Int(fields[1]).map { .okVersion($0) }
        case ("held", 3):
            guard let seconds = Int(fields[1]),
                  let setting = SleepDisabled(rawValue: String(fields[2])) else { return nil }
            return .held(secondsRemaining: seconds, setting: setting)
        case ("free", 2):
            guard let setting = SleepDisabled(rawValue: String(fields[1])) else { return nil }
            return .free(setting: setting)
        case ("error", 2):
            guard let error = PowerError(rawValue: String(fields[1])) else { return nil }
            return .error(error)
        default: return nil
        }
    }
}
