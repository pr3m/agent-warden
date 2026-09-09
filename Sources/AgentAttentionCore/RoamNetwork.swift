import Foundation

/// What sort of network roam is running over.
public enum HotspotKind: String, Sendable, Equatable {
    /// iPhone Personal Hotspot, recognised by gateway prefix 172.20.10.
    case iphone
    /// Android device hotspot, recognised by gateway prefix 192.168.43.
    case android
    /// Windows Mobile Hotspot, recognised by gateway prefix 192.168.137.
    case windows
    /// A conventional home or office Wi-Fi network, not a phone hotspot.
    /// This includes most residential gateways (10.x, 192.168.x, 172.16-31.x) and
    /// is the case that should produce a warning: loss of connectivity at the café door.
    case ordinary
    /// No network connection at all: gateway is nil, empty, or whitespace-only.
    case offline

    public var isHotspot: Bool {
        self == .iphone || self == .android || self == .windows
    }

    public var label: String {
        switch self {
        case .iphone: return "iPhone Personal Hotspot"
        case .android: return "Android hotspot"
        case .windows: return "Windows Mobile Hotspot"
        case .ordinary: return "an ordinary network"
        case .offline: return "no network"
        }
    }
}

/// Telling "you are tethered to your phone" from "you are on the café's Wi-Fi and will
/// lose it at the door".
///
/// **The gateway is the primary signal, and the SSID is best-effort.** Reading the gateway
/// needs no permission at all; SSID access is increasingly privacy-gated on modern macOS
/// and Apple has been closing the command-line routes since macOS 14. So nothing here may
/// depend on a name — an unreadable SSID makes the warning vaguer, never absent.
///
/// These ranges are heuristics and are documented as such: Android vendors vary, USB
/// tethering matches none of them, and IPv6-only routes exist. That is tolerable because
/// this drives a *warning* and never a block. Being wrong costs a sentence, not a session.
public enum RoamNetwork {
    public static func classify(gateway: String?) -> HotspotKind {
        guard let gateway = gateway?.trimmingCharacters(in: .whitespacesAndNewlines),
              !gateway.isEmpty else { return .offline }
        // Prefix match on a whole dotted octet, so "9192.168.43.1" cannot pass as one.
        let octets = gateway.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return .ordinary }
        switch (octets[0], octets[1], octets[2]) {
        case ("172", "20", "10"): return .iphone
        case ("192", "168", "43"): return .android
        case ("192", "168", "137"): return .windows
        default: return .ordinary
        }
    }
}

/// What the machine looks like when somebody may have come back to it.
public struct DeskReading: Sendable, Equatable {
    public var lidOpen: Bool
    public var hidIdleSeconds: Int
    public var roamAge: TimeInterval
    public init(lidOpen: Bool, hidIdleSeconds: Int, roamAge: TimeInterval) {
        self.lidOpen = lidOpen
        self.hidIdleSeconds = hidIdleSeconds
        self.roamAge = roamAge
    }
}

/// Whether to ask "you seem to be at the desk — still need roam?".
///
/// All three signals are required together, because each on its own is an ordinary state.
/// An open lid means nothing during a coffee break; recent typing means nothing thirty
/// seconds after entering roam. A prompt that fires on one signal is a prompt people
/// silence, and a silenced prompt protects nobody.
public enum NudgePolicy {
    /// Typing within this long counts as "somebody is here". 120 seconds is two minutes;
    /// this threshold marks the boundary between "actively using now" (typing, scrolling)
    /// and "the user walked away and the machine's idle timer is counting up". At 120s,
    /// recent typing is evidence of presence; at 121s, it is not.
    public static let activeWithinSeconds = 120
    /// Roam must have been on at least this long before the question is worth asking.
    /// 300 seconds is five minutes; at less than this, the user may still be intentionally
    /// absent (stepping out for a moment, starting a roam session while still at the desk).
    /// At 300s or more, enough time has passed that a return to the desk with the lid open
    /// and recent typing is statistically likely to be unintentional roam continuation.
    public static let settleSeconds: TimeInterval = 300

    public static func shouldNudge(_ reading: DeskReading, snoozedUntil: Date?,
                                   now: Date = Date()) -> Bool {
        if let snoozedUntil, now <= snoozedUntil { return false }
        guard reading.lidOpen else { return false }
        guard reading.hidIdleSeconds <= activeWithinSeconds else { return false }
        return reading.roamAge >= settleSeconds
    }
}
