import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("Reading the network roam is on")
struct RoamNetworkTests {

    @Test("A phone hotspot is recognised by its gateway", arguments: [
        ("172.20.10.1", HotspotKind.iphone),
        ("172.20.10.14", .iphone),
        ("192.168.43.1", .android),
        ("192.168.137.1", .windows),
    ])
    func recognisesHotspots(gateway: String, expected: HotspotKind) {
        #expect(RoamNetwork.classify(gateway: gateway) == expected)
    }

    /// Read live from this machine on 2026-09-09: an ordinary home network, which is
    /// exactly the case that should produce a warning before the lid closes.
    @Test("An ordinary network is not a hotspot")
    func ordinaryNetwork() {
        #expect(RoamNetwork.classify(gateway: "192.168.2.1") == .ordinary)
        #expect(RoamNetwork.classify(gateway: "10.0.0.1") == .ordinary)
    }

    @Test("No gateway means offline, not ordinary")
    func offline() {
        #expect(RoamNetwork.classify(gateway: nil) == .offline)
        #expect(RoamNetwork.classify(gateway: "") == .offline)
        #expect(RoamNetwork.classify(gateway: "   ") == .offline)
    }

    /// The ranges are prefixes, not substrings. `9192.168.43.1` is not an Android hotspot.
    @Test("A lookalike address is not a hotspot")
    func lookalikesAreOrdinary() {
        #expect(RoamNetwork.classify(gateway: "9192.168.43.1") == .ordinary)
        #expect(RoamNetwork.classify(gateway: "192.168.430.1") == .ordinary)
    }
}

@Suite("The at-the-desk nudge")
struct NudgePolicyTests {

    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func reading(lidOpen: Bool = true, idle: Int = 5,
                         age: TimeInterval = 600) -> DeskReading {
        DeskReading(lidOpen: lidOpen, hidIdleSeconds: idle, roamAge: age)
    }

    @Test("Lid open, recently typing, roam on a while — worth asking")
    func nudgesWhenClearlyAtTheDesk() {
        #expect(NudgePolicy.shouldNudge(reading(), snoozedUntil: nil, now: now))
    }

    /// Every one of these on its own is an ordinary state, not evidence. Nagging on a
    /// closed lid, or thirty seconds after entering roam, is how a helpful prompt becomes
    /// something people turn off.
    @Test("Any single missing signal means no nudge")
    func staysQuietWithoutAllThree() {
        #expect(!NudgePolicy.shouldNudge(reading(lidOpen: false), snoozedUntil: nil, now: now))
        #expect(!NudgePolicy.shouldNudge(reading(idle: 600), snoozedUntil: nil, now: now))
        #expect(!NudgePolicy.shouldNudge(reading(age: 30), snoozedUntil: nil, now: now))
    }

    @Test("A dismissed nudge stays dismissed for its window")
    func respectsSnooze() {
        let until = now.addingTimeInterval(300)
        #expect(!NudgePolicy.shouldNudge(reading(), snoozedUntil: until, now: now))
        #expect(NudgePolicy.shouldNudge(reading(), snoozedUntil: until,
                                        now: until.addingTimeInterval(1)))
    }
}
