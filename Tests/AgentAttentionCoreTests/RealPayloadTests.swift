import Foundation
import Testing
@testable import AgentAttentionCore

/// Fixtures taken from payloads Claude Code actually delivered on this machine, not from what the
/// implementation happens to expect.
///
/// They were captured by a `Notification` hook with no matcher, which logged every string field of
/// every payload it received (Claude Code 2.1.261, September 2026). Three shapes were observed:
///
///     hook_event_name=Notification  message=Claude needs your permission              notification_type=permission_prompt
///     hook_event_name=Notification  message=Claude is waiting for your input          notification_type=idle_prompt
///     hook_event_name=Notification  message=Claude Code needs your approval for the plan  notification_type=permission_prompt
///
/// Two things follow, and both are load-bearing:
///
/// 1. The text lives in **`message`**. An earlier implementation read `notification_text`, found
///    nothing, and silently fell back to a generic label — no crash, no error, just a worse card.
///    Hence the multi-spelling lookup and this file.
/// 2. Approving a plan arrives as a plain `permission_prompt`, indistinguishable from any other
///    permission. The specific "a plan is waiting" signal comes from `PreToolUse/ExitPlanMode`
///    moments earlier — which is exactly why a later, vaguer signal must not overwrite it.
@Suite("Observed Claude Code payloads")
struct RealPayloadTests {

    /// The full payload shape, including the three long fields the capture stripped for brevity.
    private func notification(type: String, message: String) -> [String: Any] {
        [
            "session_id": "80373ad6-40c1-477a-9aa0-b400a7fbda51",
            "prompt_id": "6bed4363-817a-4c38-a080-8393badcad1d",
            "transcript_path": "/Users/dev/.claude/projects/alpha/80373ad6.jsonl",
            "cwd": "/Users/dev/code/alpha",
            "hook_event_name": "Notification",
            "message": message,
            "notification_type": type,
        ]
    }

    @Test("A real permission prompt is classified as an approval")
    func permissionPrompt() {
        let result = HookTranslator.classify(notification(type: "permission_prompt", message: "Claude needs your permission"))
        #expect(result.signal == .attention)
        #expect(result.attentionKind == .approval)
        #expect(result.messageDetail == "Claude needs your permission")
    }

    @Test("A real idle prompt is classified as idle")
    func idlePrompt() {
        let result = HookTranslator.classify(notification(type: "idle_prompt", message: "Claude is waiting for your input"))
        #expect(result.attentionKind == .idle)
        #expect(result.messageDetail == "Claude is waiting for your input")
    }

    @Test("The message field is read under both spellings")
    func messageFieldAliases() {
        var payload = notification(type: "permission_prompt", message: "Claude needs your permission")
        #expect(HookTranslator.classify(payload).messageDetail == "Claude needs your permission")

        // Same event, documented under the other name.
        payload["message"] = nil
        payload["notification_text"] = "Claude needs your permission"
        #expect(HookTranslator.classify(payload).messageDetail == "Claude needs your permission")
    }

    @Test("Session lifecycle reasons are read under both spellings")
    func lifecycleFieldAliases() {
        let common: [String: Any] = ["session_id": "s1", "cwd": "/Users/dev/code/alpha"]

        var start = common
        start["hook_event_name"] = "SessionStart"
        start["source"] = "resume"
        #expect(HookTranslator.classify(start).detail == "resume")
        start["source"] = nil
        start["startup_reason"] = "resume"
        #expect(HookTranslator.classify(start).detail == "resume")

        var end = common
        end["hook_event_name"] = "SessionEnd"
        end["reason"] = "logout"
        #expect(HookTranslator.classify(end).detail == "logout")
        end["reason"] = nil
        end["end_reason"] = "logout"
        #expect(HookTranslator.classify(end).detail == "logout")
    }

    @Test("Message text is not stored unless the user asks for it")
    func messagesAreOptIn() {
        let result = HookTranslator.classify(notification(type: "permission_prompt", message: "Claude needs your permission"))
        #expect(result.resolvedDetail(includeMessages: false) == AttentionKind.approval.staticDetail)
        #expect(result.resolvedDetail(includeMessages: true) == "Claude needs your permission")
    }

    @Test("Nothing from a real payload beyond the nine fields we read is ever emitted")
    func nothingElseIsRecorded() throws {
        let payload = notification(type: "permission_prompt", message: "Claude needs your permission")
        let outcome = HookIngestion.process(
            payload: payload,
            identity: Fixture.identity(session: "80373ad6-40c1-477a-9aa0-b400a7fbda51"),
            now: Fixture.origin,
            config: .default
        )
        let encoded = try String(data: JSONCoding.encoder.encode(#require(outcome.event)), encoding: .utf8) ?? ""
        #expect(!encoded.contains("80373ad6.jsonl"), "transcript path must never be recorded")
        #expect(!encoded.contains("6bed4363"), "prompt id is not ours to keep")
    }

    /// The sequence that produced the observed "needs your approval for the plan" message: the
    /// plan-mode tool call first, then Claude Code's own generic permission notification.
    @Test("A plan approval keeps its specific description when the generic prompt follows")
    func planApprovalKeepsItsDescription() {
        let (engine, clock, _) = makeEngine()
        let identity = Fixture.identity(session: "s1")

        let exitPlan = HookTranslator.classify([
            "hook_event_name": "PreToolUse", "session_id": "s1",
            "cwd": identity.cwd, "tool_name": "ExitPlanMode",
        ])
        #expect(exitPlan.attentionKind == .stageDecision)
        engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .stageDecision,
            detail: AttentionKind.stageDecision.staticDetail, at: clock.now,
            hookEvent: "PreToolUse", identity: identity
        ))
        #expect(engine.pendingCount == 1)

        clock.advance(6)
        let generic = HookTranslator.classify(notification(type: "permission_prompt", message: "Claude Code needs your approval for the plan"))
        #expect(generic.attentionKind == .approval)
        let effects = engine.ingest(Fixture.event(
            session: "s1", signal: .attention, kind: .approval,
            detail: AttentionKind.approval.staticDetail, at: clock.now, identity: identity
        ))

        #expect(effects.raisedItems.isEmpty, "the same wait must not be announced twice")
        #expect(engine.pendingCount == 1)
        #expect(engine.visibleItems().first?.kind == .stageDecision, "the specific description survives the vague one")
        #expect(engine.visibleItems().first?.occurrences == 2)
    }
}
