import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Builds the "where does this session live" record from the hook payload, the inherited
/// environment and the process tree. Nothing here reads credentials, transcripts or prompt text.
public enum SessionIdentityBuilder {
    public static func build(
        payload: [String: Any],
        environment: [String: String],
        pid: Int32,
        locate: (Int32) -> (claude: ProcSnapshot?, terminalAppPath: String?) = ProcessProbe.locateSession
    ) -> SessionIdentity {
        let sessionID = HookTranslator.string(payload, "session_id") ?? "unknown"
        let cwd = HookTranslator.string(payload, "cwd") ?? FileManager.default.currentDirectoryPath

        let located = locate(pid)
        let tmux = environment["TMUX"]
        let tmuxSocket = tmux?.split(separator: ",").first.map(String.init)

        return SessionIdentity(
            sessionID: sessionID,
            cwd: cwd,
            claudePID: located.claude?.pid,
            claudePIDStartedAt: located.claude?.startedAt,
            tty: located.claude?.tty,
            termProgram: environment["TERM_PROGRAM"],
            termSessionID: environment["TERM_SESSION_ID"],
            itermSessionID: environment["ITERM_SESSION_ID"],
            tmuxPane: environment["TMUX_PANE"],
            tmuxSocket: tmuxSocket,
            terminalAppPath: located.terminalAppPath
        )
    }
}

/// Turns one hook invocation into the two things we persist: a heartbeat (always) and a spooled
/// event (only when it is worth the app's attention or changes session lifecycle).
public enum HookIngestion {
    /// What the installed hook entry says this event is.
    ///
    /// The installed entries carry the classification as an argument, decided by Claude Code's own
    /// matcher (`Notification` with `matcher: "permission_prompt"`, and so on). That makes normal
    /// operation independent of payload field names — the part of the contract most likely to
    /// drift. The payload classification remains as the fallback.
    public struct Override: Sendable, Equatable {
        public var signal: SignalClass?
        public var kind: AttentionKind?
        public var detail: String?

        public init(signal: SignalClass? = nil, kind: AttentionKind? = nil, detail: String? = nil) {
            self.signal = signal
            self.kind = kind
            self.detail = detail
        }

        public var isEmpty: Bool { signal == nil && kind == nil && detail == nil }
    }

    public struct Outcome: Sendable {
        public var heartbeat: SessionHeartbeat
        public var event: EmittedEvent?
        public var classification: HookTranslator.Classification
    }

    public static func process(
        payload: [String: Any],
        identity: SessionIdentity,
        now: Date,
        config: AttentionConfig = .default,
        override: Override = Override()
    ) -> Outcome {
        let classification = HookTranslator.classify(payload)
        let hookEvent = HookTranslator.string(payload, "hook_event_name") ?? override.signal.map { "(\($0.rawValue))" } ?? "unknown"

        // The installed hook entries carry a classification decided when they were written:
        // `Stop --kind workComplete`, `SubagentStop --signal activity`. That argument still decides
        // — except where the payload itself supports something *more specific about the same
        // event*, in which case the specific reading wins. Two cases, both narrow:
        //
        // 1. a generic override (`workComplete`, `idle`) yields to a real request read from the
        //    payload. `Stop --kind workComplete` on a turn that handed a decision back is a
        //    handoff, not a completion;
        // 2. `--signal activity` yields to housekeeping for the events that *are* housekeeping.
        //    A subagent stopping was only ever called activity because there was no better word.
        //
        // Nothing here can make an event less specific, and an explicit non-generic override
        // (`--kind approval`) is never second-guessed. An existing installation therefore gets the
        // corrected behaviour with no change to `settings.json`.
        var kind = override.kind ?? classification.attentionKind
        if let overridden = override.kind, overridden.isGeneric,
           let fromPayload = classification.attentionKind, !fromPayload.isGeneric {
            kind = fromPayload
        }
        var signal: SignalClass = override.kind != nil ? .attention : (override.signal ?? classification.signal)
        if override.kind == nil, override.signal == .activity, classification.signal == .housekeeping {
            signal = .housekeeping
        }

        let heartbeat = SessionHeartbeat(
            identity: identity,
            lastEventAt: now,
            lastHookEvent: hookEvent,
            lastSignal: signal
        )

        // Ordinary work never touches the spool — one file per tool call would be pure churn. The
        // same goes for housekeeping: a subagent starting and stopping is proof of life, which the
        // heartbeat already carries, and spooling it would add files that say nothing new.
        guard signal != .activity, signal != .housekeeping else {
            return Outcome(heartbeat: heartbeat, event: nil, classification: classification)
        }

        let detail = override.detail
            ?? classification.resolvedDetail(includeMessages: config.includeHookMessages)
            ?? kind?.staticDetail

        // Only `Stop` carries the task arrays, and only counts are taken from them.
        let background: BackgroundEvidence? = hookEvent == "Stop"
            ? BackgroundEvidence.read(from: payload, now: now)
            : nil

        let event = EmittedEvent(
            hookEvent: hookEvent,
            signal: signal,
            attentionKind: signal == .attention ? kind : nil,
            source: classification.source,
            detail: detail.map { HookTranslator.truncate($0) },
            occurredAt: now,
            identity: identity,
            background: background,
            awaitsUserAcceptance: classification.awaitsUserAcceptance
        )
        return Outcome(heartbeat: heartbeat, event: event, classification: classification)
    }
}
