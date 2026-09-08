import Foundation
import Testing
@testable import AgentAttentionCore

/// Shared fixtures. Every test that touches disk gets its own temporary root, so a test run can
/// never read or write the real `~/Library/Application Support/AgentAttention`.
enum Fixture {
    static let origin = Date(timeIntervalSince1970: 1_760_000_000)

    static func identity(
        session: String,
        project: String = "alpha",
        pid: Int32? = 4242,
        startedAt: Double? = 1_759_000_000,
        termProgram: String? = "ghostty",
        itermSessionID: String? = nil,
        tty: String? = nil,
        terminalAppPath: String? = "/Applications/Ghostty.app",
        tmuxPane: String? = nil
    ) -> SessionIdentity {
        SessionIdentity(
            sessionID: session,
            cwd: "/Users/dev/code/\(project)",
            claudePID: pid,
            claudePIDStartedAt: startedAt,
            tty: tty,
            termProgram: termProgram,
            termSessionID: nil,
            itermSessionID: itermSessionID,
            tmuxPane: tmuxPane,
            tmuxSocket: nil,
            terminalAppPath: terminalAppPath
        )
    }

    static func event(
        session: String,
        signal: SignalClass,
        kind: AttentionKind? = nil,
        source: SignalSource = .explicit,
        detail: String? = nil,
        at: Date,
        hookEvent: String = "Notification",
        id: String = UUID().uuidString,
        identity: SessionIdentity? = nil,
        background: BackgroundEvidence? = nil,
        awaitsUserAcceptance: Bool = false
    ) -> EmittedEvent {
        EmittedEvent(
            id: id,
            hookEvent: hookEvent,
            signal: signal,
            attentionKind: kind,
            source: source,
            detail: detail,
            occurredAt: at,
            identity: identity ?? Fixture.identity(session: session),
            background: background,
            awaitsUserAcceptance: awaitsUserAcceptance
        )
    }

    /// A `Stop` whose two task arrays both read cleanly and are empty.
    ///
    /// This is the **only** shape that confirms a turn finished, so it is the only one that may
    /// produce a completion card. A bare `workComplete` with no evidence is a different thing —
    /// uncertain, and deliberately silent — so a test that means "the turn finished" has to say so.
    static func turnComplete(
        session: String,
        at moment: Date,
        identity: SessionIdentity? = nil,
        id: String = UUID().uuidString
    ) -> EmittedEvent {
        event(session: session, signal: .attention, kind: .workComplete, at: moment,
              hookEvent: "Stop", id: id, identity: identity,
              background: BackgroundEvidence(availability: .none, observedAt: moment))
    }

    static func temporaryPaths() throws -> AppPaths {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-attention-tests")
            .appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(root: base)
        try paths.createDirectories()
        return paths
    }
}

extension Array where Element == EngineEffect {
    var raisedItems: [AttentionItem] {
        compactMap { if case let .raised(item) = $0 { return item } else { return nil } }
    }

    var repeatedItems: [AttentionItem] {
        compactMap { if case let .repeated(item) = $0 { return item } else { return nil } }
    }

    var unsnoozedItems: [AttentionItem] {
        compactMap { if case let .unsnoozed(item) = $0 { return item } else { return nil } }
    }

    var resolutionReasons: [EngineEffect.ResolutionReason] {
        compactMap { if case let .resolved(_, reason) = $0 { return reason } else { return nil } }
    }

    var dropReasons: [EngineEffect.DropReason] {
        compactMap { if case let .sessionDropped(_, reason) = $0 { return reason } else { return nil } }
    }
}

/// Builds an engine wired to a manually advanced clock and a fake process table.
func makeEngine(
    config: AttentionConfig = .default,
    clock: TestClock = TestClock(Fixture.origin),
    liveness: StubLiveness = StubLiveness(),
    restoring snapshot: EngineSnapshot? = nil
) -> (AttentionEngine, TestClock, StubLiveness) {
    let engine = AttentionEngine(config: config, clock: clock, liveness: liveness, restoring: snapshot)
    return (engine, clock, liveness)
}
