import Foundation
import Testing
@testable import AgentAttentionCore

/// The fast path for very large hook payloads must agree with the ordinary parse.
@Suite("Shallow JSON scanning")
struct ShallowJSONTests {

    private func scan(_ object: [String: Any]) throws -> [String: String] {
        let data = try JSONSerialization.data(withJSONObject: object)
        return ShallowJSON.topLevelStrings(from: data, keys: HookTranslator.interestingKeys)
    }

    @Test("It finds the fields we care about")
    func findsTopLevelFields() throws {
        let scanned = try scan([
            "hook_event_name": "Notification",
            "session_id": "abc-123",
            "cwd": "/Users/dev/code/alpha",
            "notification_type": "permission_prompt",
            "notification_text": "Claude needs your permission to use Bash",
        ])
        #expect(scanned["hook_event_name"] == "Notification")
        #expect(scanned["session_id"] == "abc-123")
        #expect(scanned["cwd"] == "/Users/dev/code/alpha")
        #expect(scanned["notification_text"] == "Claude needs your permission to use Bash")
    }

    @Test("A nested key of the same name cannot be mistaken for the real one")
    func nestingIsRespected() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PostToolUse",
            "cwd": "/real/cwd",
            "tool_input": ["cwd": "/fake/cwd", "session_id": "fake-session"],
            "session_id": "real-session",
        ] as [String: Any])
        let scanned = ShallowJSON.topLevelStrings(from: data, keys: HookTranslator.interestingKeys)
        #expect(scanned["cwd"] == "/real/cwd")
        #expect(scanned["session_id"] == "real-session")
    }

    @Test("Keys inside arrays of objects are ignored")
    func arraysAreRespected() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PostToolBatch",
            "session_id": "real",
            "tool_results": [["tool_name": "Bash", "session_id": "nope"], ["tool_name": "Read"]],
        ] as [String: Any])
        let scanned = ShallowJSON.topLevelStrings(from: data, keys: HookTranslator.interestingKeys)
        #expect(scanned["session_id"] == "real")
        #expect(scanned["tool_name"] == nil)
    }

    @Test("Escapes and unicode survive the scan")
    func escapesAreDecoded() throws {
        let scanned = try scan([
            "hook_event_name": "Notification",
            "notification_text": "line1\nline2 \"quoted\" back\\slash émoji 🐢",
        ])
        #expect(scanned["notification_text"] == "line1\nline2 \"quoted\" back\\slash émoji 🐢")
    }

    @Test("A key whose value is not a string is skipped, matching the ordinary parse")
    func nonStringValues() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification",
            "notification_text": 42,
            "session_id": "abc",
        ] as [String: Any])
        let scanned = ShallowJSON.topLevelStrings(from: data, keys: HookTranslator.interestingKeys)
        #expect(scanned["notification_text"] == nil)
        #expect(scanned["session_id"] == "abc")
        #expect(HookTranslator.string(scanned as [String: Any], "notification_text") == nil)
    }

    @Test("A huge payload classifies exactly like the small one")
    func hugePayloadMatchesSmall() throws {
        var payload: [String: Any] = [
            "hook_event_name": "Notification",
            "session_id": "abc-123",
            "cwd": "/Users/dev/code/alpha",
            "notification_type": "permission_prompt",
            "notification_text": "Claude needs your permission to use Bash",
        ]
        let small = HookTranslator.classify(payload)

        payload["tool_output"] = String(repeating: "x", count: 2 * ShallowJSON.fullParseLimit)
        let data = try JSONSerialization.data(withJSONObject: payload)
        #expect(data.count > ShallowJSON.fullParseLimit)

        let large = HookTranslator.classify(ShallowJSON.payload(from: data, keys: HookTranslator.interestingKeys))
        #expect(large == small)
    }

    @Test("Small payloads still take the fully validating parse")
    func smallPayloadsUseFullParse() throws {
        let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s"])
        let parsed = ShallowJSON.payload(from: data, keys: HookTranslator.interestingKeys)
        #expect(parsed["hook_event_name"] as? String == "Stop")
    }

    @Test("Malformed input yields nothing rather than crashing", arguments: [
        "", "not json", "{", #"{"session_id": "unterminated"#, "[]", "null", #"{"a":"#,
    ])
    func malformedInput(text: String) {
        let data = Data(text.utf8)
        _ = ShallowJSON.payload(from: data, keys: HookTranslator.interestingKeys)
        _ = ShallowJSON.topLevelStrings(from: data, keys: HookTranslator.interestingKeys)
        // Reaching here without a crash or a hang is the assertion.
        #expect(Bool(true))
    }

    @Test("A truncated large payload keeps whatever it managed to read")
    func truncatedLargePayload() {
        // Key order is written by hand: JSONSerialization does not preserve it, and this test is
        // specifically about what survives a cut at a known position.
        let filler = String(repeating: "x", count: 2 * ShallowJSON.fullParseLimit)
        let json = #"{"hook_event_name":"Stop","session_id":"abc-123","tool_output":"\#(filler)"}"#
        let data = Data(json.utf8).prefix(json.utf8.count - 10)

        let scanned = ShallowJSON.payload(from: data, keys: HookTranslator.interestingKeys)
        #expect(scanned["session_id"] as? String == "abc-123")
        #expect(HookTranslator.classify(scanned).attentionKind == .workComplete)
    }

    @Test("A payload cut before the fields we need degrades to ordinary activity, not an alert")
    func truncatedBeforeTheFieldsWeNeed() {
        let filler = String(repeating: "x", count: 2 * ShallowJSON.fullParseLimit)
        let json = #"{"tool_output":"\#(filler)","hook_event_name":"Stop"}"#
        let data = Data(json.utf8).prefix(ShallowJSON.fullParseLimit + 100)

        let scanned = ShallowJSON.payload(from: data, keys: HookTranslator.interestingKeys)
        #expect(HookTranslator.classify(scanned).signal == .activity, "a half-read payload must never invent an alert")
    }
}
