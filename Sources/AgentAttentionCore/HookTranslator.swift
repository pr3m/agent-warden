import Foundation

/// Turns a raw Claude Code hook payload into the one classification this app cares about.
///
/// Field names are read under more than one spelling on purpose. The payloads observed from
/// Claude Code 2.1.x carry the notification text in `message`, while some documentation renders
/// it as `notification_text`; the same applies to `source`/`startup_reason` and
/// `reason`/`end_reason`. Reading both costs nothing and means a rename upstream cannot silently
/// turn the app deaf. `Tests/…/RealPayloadTests.swift` pins the observed shapes.
///
/// This is only a fallback path. The installed hook entries pass the classification as an explicit
/// argument (`--signal` / `--kind`), decided by Claude Code's own matcher, so normal operation does
/// not depend on payload field names at all.
public enum HookTranslator {
    public struct Classification: Sendable, Equatable {
        public var signal: SignalClass
        public var attentionKind: AttentionKind?
        public var source: SignalSource
        /// Safe reason: a static label, or something structural like a tool name.
        public var detail: String?
        /// The hook's own message text. Only stored when the user opts in — see
        /// `AttentionConfig.includeHookMessages`.
        public var messageDetail: String?
        /// The handoff asked the user to try, test or review the work. Only the user can close it.
        public var awaitsUserAcceptance: Bool = false

        public init(
            signal: SignalClass,
            attentionKind: AttentionKind? = nil,
            source: SignalSource = .explicit,
            detail: String? = nil,
            messageDetail: String? = nil,
            awaitsUserAcceptance: Bool = false
        ) {
            self.signal = signal
            self.attentionKind = attentionKind
            self.source = source
            self.detail = detail
            self.messageDetail = messageDetail
            self.awaitsUserAcceptance = awaitsUserAcceptance
        }

        /// The reason to record, given the user's preference about message text.
        public func resolvedDetail(includeMessages: Bool) -> String? {
            if includeMessages, let messageDetail, !messageDetail.isEmpty { return messageDetail }
            if let detail, !detail.isEmpty { return detail }
            return attentionKind?.staticDetail
        }
    }

    /// Every payload field this app ever looks at, under every spelling we accept. Nothing else is
    /// read — in particular not `prompt_text`, `prompt`, `tool_input`, `tool_output` or
    /// `transcript_path`.
    ///
    /// `last_assistant_message` is **read and never stored**. It is parsed in memory to tell a turn
    /// that handed something back from a turn that simply finished; what reaches disk is a static
    /// reason, unless the user has opted into message text, in which case a short excerpt of the
    /// request may be kept like any other hook message.
    public static let interestingKeys: Set<String> = [
        "hook_event_name", "session_id", "cwd", "tool_name",
        "notification_type", "message", "notification_text",
        "error_type", "source", "startup_reason", "reason", "end_reason",
        "last_assistant_message",
    ]

    /// Tools whose *invocation* is itself a request for the human.
    static let questionTools: Set<String> = ["AskUserQuestion"]
    /// Tools that mark a meaningful stage boundary needing a human decision.
    static let stageDecisionTools: Set<String> = ["ExitPlanMode"]

    public static func classify(_ payload: [String: Any]) -> Classification {
        let event = string(payload, "hook_event_name") ?? ""

        switch event {
        case "SessionStart":
            return Classification(signal: .sessionStart, detail: string(payload, "source", "startup_reason"))

        case "SessionEnd":
            return Classification(signal: .sessionEnd, detail: string(payload, "reason", "end_reason"))

        case "PreToolUse":
            let tool = string(payload, "tool_name") ?? ""
            if questionTools.contains(tool) {
                return Classification(signal: .attention, attentionKind: .question)
            }
            if stageDecisionTools.contains(tool) {
                return Classification(signal: .attention, attentionKind: .stageDecision)
            }
            return Classification(signal: .activity)

        case "PermissionRequest":
            let tool = string(payload, "tool_name")
            return Classification(
                signal: .attention,
                attentionKind: .approval,
                detail: tool.map { "Permission needed: \($0)" }
            )

        case "Notification":
            return classifyNotification(payload)

        case "Stop":
            // The turn ended. *How* it ended is the question: with a decision handed back, or with
            // nothing needed. Claude Code's hook documentation provides `last_assistant_message`
            // for exactly this and recommends it over reading the transcript, because the final
            // text may not be on disk yet. It is read here and never stored — see `FinalHandoff`.
            let handoff = FinalHandoff.read(string(payload, "last_assistant_message"))
            if handoff.asksForSomething {
                return Classification(
                    signal: .attention,
                    attentionKind: .handoff,
                    // The static reason is what gets persisted by default; the excerpt is offered
                    // only for the opt-in path, exactly like a hook's own message text.
                    // An acceptance checkpoint says so in the reason, because "waiting for you"
                    // and "waiting for you to try it" ask for different things from a reader.
                    detail: handoff.awaitsUserAcceptance
                        ? "Handed to you to test or review"
                        : AttentionKind.handoff.staticDetail,
                    messageDetail: handoff.excerpt.map { "Asked you: \(truncate($0, limit: 120))" },
                    awaitsUserAcceptance: handoff.awaitsUserAcceptance
                )
            }
            // A footer that said `nothing` has already answered the question this scan asks. Going
            // on to read the rest of the message would let a closing line underneath an explicit
            // "nothing needed" raise a checkpoint the turn just said was not needed.
            guard handoff.reason != .explicitlyNothing else {
                return Classification(signal: .attention, attentionKind: .workComplete)
            }
            // No dedicated footer — but a turn can hand work over in an ordinary sentence, and the
            // examples that matter ("UAT steps are here", "please test the updated functionality")
            // do exactly that. Read for a *current* acceptance request only; everything else about
            // the message is still ignored.
            let standalone = FinalHandoff.readStandaloneAcceptance(
                string(payload, "last_assistant_message"))
            if standalone.awaitsUserAcceptance {
                return Classification(
                    signal: .attention,
                    attentionKind: .handoff,
                    detail: "Handed to you to test or review",
                    messageDetail: standalone.excerpt.map { "Asked you: \(truncate($0, limit: 120))" },
                    awaitsUserAcceptance: true
                )
            }
            return Classification(signal: .attention, attentionKind: .workComplete)

        case "StopFailure":
            let type = string(payload, "error_type") ?? "unknown"
            return Classification(signal: .attention, attentionKind: .error, detail: "Turn failed: \(type)")

        case "SubagentStop", "SubagentStart":
            // A child starting or finishing is proof the session is alive, and nothing else. Treating
            // it as the session working is what let a subagent's completion mark a parent "working"
            // moments after that parent had asked for a decision — and quietly close the request.
            return Classification(signal: .housekeeping)

        case "PostToolUse", "PostToolUseFailure", "PostToolBatch",
             "UserPromptSubmit", "UserPromptExpansion",
             "PreCompact", "PostCompact", "CwdChanged":
            // The session itself, doing something. This is what genuinely resumes a turn.
            return Classification(signal: .activity)

        default:
            // Anything else we are wired to still counts as "the session is alive and busy".
            return Classification(signal: .activity)
        }
    }

    private static func classifyNotification(_ payload: [String: Any]) -> Classification {
        let type = string(payload, "notification_type") ?? ""
        let message = string(payload, "message", "notification_text").map { truncate($0, limit: 120) }

        func attention(_ kind: AttentionKind) -> Classification {
            Classification(signal: .attention, attentionKind: kind, messageDetail: message)
        }

        switch type {
        case "permission_prompt":
            return attention(.approval)
        case "agent_needs_input":
            return attention(.question)
        case "elicitation_dialog", "elicitation_url_dialog":
            return attention(.question)
        case "idle_prompt":
            return attention(.idle)
        case "agent_completed":
            return attention(.workComplete)
        case "quota_auto_resume_stale", "quota_auto_resume_disabled":
            return attention(.error)
        default:
            // auth_success, elicitation_complete, elicitation_response, quota_auto_resume_fired…
            // Not worth interrupting for, but proof the session is alive.
            return Classification(signal: .activity)
        }
    }

    // MARK: - helpers

    /// First non-empty string among the accepted spellings of a field.
    static func string(_ payload: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Keep event records short and single-line. Long free text is neither useful on a card nor
    /// something we want sitting on disk.
    public static func truncate(_ text: String, limit: Int = 160) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}
