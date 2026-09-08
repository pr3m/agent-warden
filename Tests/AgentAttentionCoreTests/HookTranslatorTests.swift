import Foundation
import Testing
@testable import AgentAttentionCore

/// Mapping from Claude Code hook payloads to what the queue should do.
/// Shapes observed in the wild are pinned separately, in `RealPayloadTests`.
@Suite("Hook translation")
struct HookTranslatorTests {

    private func payload(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "session_id": "abc-123",
            "cwd": "/Users/dev/code/alpha",
            "hook_event_name": event,
        ]
        for (key, value) in extra { base[key] = value }
        return base
    }

    @Test("Lifecycle events are recognised")
    func lifecycle() {
        #expect(HookTranslator.classify(payload("SessionStart", ["source": "startup"])).signal == .sessionStart)
        #expect(HookTranslator.classify(payload("SessionEnd", ["reason": "logout"])).signal == .sessionEnd)
    }

    @Test("The session's own work is activity, never an alert", arguments: [
        "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PostToolBatch",
        "PreCompact", "PostCompact", "CwdChanged",
    ])
    func ordinaryWorkIsActivity(event: String) {
        #expect(HookTranslator.classify(payload(event)).signal == .activity)
    }

    @Test("A subagent starting or finishing is proof of life, not the session working",
          arguments: ["SubagentStart", "SubagentStop"])
    func subagentEventsAreHousekeeping(event: String) {
        // Deliberately not `.activity`. A child finishing had been marking the parent "working",
        // which closed a request the parent had just made.
        #expect(HookTranslator.classify(payload(event)).signal == .housekeeping)
        #expect(HookTranslator.classify(payload(event)).attentionKind == nil)
    }

    @Test("A tool call that is not a question is just work")
    func preToolUseIsActivity() {
        #expect(HookTranslator.classify(payload("PreToolUse", ["tool_name": "Bash"])).signal == .activity)
    }

    @Test("PermissionRequest is an explicit approval and names the tool")
    func permissionRequest() {
        let result = HookTranslator.classify(payload("PermissionRequest", ["tool_name": "Bash"]))
        #expect(result.signal == .attention)
        #expect(result.attentionKind == .approval)
        #expect(result.source == .explicit)
        #expect(result.detail == "Permission needed: Bash")
        #expect(result.resolvedDetail(includeMessages: false) == "Permission needed: Bash")
    }

    @Test("A tool name is structural, not message content, so it is kept without opting in")
    func toolNameIsNotMessageContent() {
        let result = HookTranslator.classify(payload("PermissionRequest", ["tool_name": "Bash"]))
        #expect(result.messageDetail == nil)
        #expect(result.resolvedDetail(includeMessages: false)?.contains("Bash") == true)
    }

    @Test("Notification types map to the right kind", arguments: [
        ("permission_prompt", AttentionKind.approval),
        ("agent_needs_input", .question),
        ("elicitation_dialog", .question),
        ("elicitation_url_dialog", .question),
        ("idle_prompt", .idle),
        ("agent_completed", .workComplete),
        ("quota_auto_resume_stale", .error),
        ("quota_auto_resume_disabled", .error),
    ])
    func notificationKinds(type: String, expected: AttentionKind) {
        let result = HookTranslator.classify(payload("Notification", ["notification_type": type]))
        #expect(result.attentionKind == expected)
        #expect(result.signal == .attention)
    }

    @Test("Notification types not worth interrupting for stay quiet", arguments: [
        "auth_success", "elicitation_complete", "elicitation_response",
        "quota_auto_resume_fired", "something_new_we_have_never_seen",
    ])
    func quietNotifications(type: String) {
        let result = HookTranslator.classify(payload("Notification", ["notification_type": type]))
        #expect(result.attentionKind == nil)
        #expect(result.signal == .activity)
    }

    @Test("AskUserQuestion and ExitPlanMode are meaningful stages")
    func stageDecisions() {
        #expect(HookTranslator.classify(payload("PreToolUse", ["tool_name": "AskUserQuestion"])).attentionKind == .question)

        let plan = HookTranslator.classify(payload("PreToolUse", ["tool_name": "ExitPlanMode"]))
        #expect(plan.attentionKind == .stageDecision)
        #expect(plan.source == .explicit)
        #expect(plan.resolvedDetail(includeMessages: false) == "Plan ready — approve to continue")
    }

    @Test("Stop and StopFailure")
    func stopEvents() {
        let stop = HookTranslator.classify(payload("Stop"))
        #expect(stop.attentionKind == .workComplete)
        #expect(stop.resolvedDetail(includeMessages: false) == "Turn complete — waiting for you")

        let failure = HookTranslator.classify(payload("StopFailure", ["error_type": "rate_limit"]))
        #expect(failure.attentionKind == .error)
        #expect(failure.detail == "Turn failed: rate_limit")
    }

    @Test("Unknown hook events degrade to activity rather than alerting")
    func unknownEvents() {
        #expect(HookTranslator.classify(payload("SomeFutureHook")).signal == .activity)
        #expect(HookTranslator.classify([:]).signal == .activity)
    }

    @Test("Missing fields still produce a usable reason")
    func missingFields() {
        #expect(HookTranslator.classify(["hook_event_name": "PermissionRequest"])
            .resolvedDetail(includeMessages: false) == "Permission needed")
        #expect(HookTranslator.classify(["hook_event_name": "Notification", "notification_type": "permission_prompt"])
            .resolvedDetail(includeMessages: true) == "Permission needed")
        #expect(HookTranslator.classify(["hook_event_name": "StopFailure"]).detail == "Turn failed: unknown")
    }

    @Test("Wrong types in the payload are treated as missing")
    func wrongTypes() {
        let result = HookTranslator.classify([
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "message": 42,
        ])
        #expect(result.attentionKind == .approval)
        #expect(result.messageDetail == nil)
        #expect(result.resolvedDetail(includeMessages: true) == "Permission needed")
    }

    @Test("Detail is truncated to one short line")
    func truncation() {
        let long = String(repeating: "x", count: 400) + "\nsecond line"
        let truncated = HookTranslator.truncate(long)
        #expect(truncated.count == 160)
        #expect(!truncated.contains("\n"))
        #expect(HookTranslator.truncate("short") == "short")
    }

    @Test("A long notification message is capped before it is ever stored")
    func longMessageIsCapped() {
        let result = HookTranslator.classify([
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "message": String(repeating: "y", count: 5000),
        ])
        #expect((result.messageDetail?.count ?? 0) <= 120)
    }

    @Test("An explicit argument beats whatever the payload says")
    func overrideWins() {
        // The installed hook entries state the classification, decided by Claude Code's own
        // matcher. A payload whose fields have been renamed upstream must not defeat that.
        let outcome = HookIngestion.process(
            payload: ["hook_event_name": "Notification", "session_id": "s1", "renamed_type_field": "permission_prompt"],
            identity: Fixture.identity(session: "s1"),
            now: Fixture.origin,
            config: .default,
            override: HookIngestion.Override(kind: .approval)
        )
        #expect(outcome.event?.signal == .attention)
        #expect(outcome.event?.attentionKind == .approval)
        #expect(outcome.event?.detail == "Permission needed")
    }

    @Test("An explicit activity argument keeps an unknown event out of the spool")
    func overrideActivity() {
        let outcome = HookIngestion.process(
            payload: ["hook_event_name": "SomethingNew", "session_id": "s1"],
            identity: Fixture.identity(session: "s1"),
            now: Fixture.origin,
            config: .default,
            override: HookIngestion.Override(signal: .activity)
        )
        #expect(outcome.event == nil)
        #expect(outcome.heartbeat.lastSignal == .activity)
    }
}
