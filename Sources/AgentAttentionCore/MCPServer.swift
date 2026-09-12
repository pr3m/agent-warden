import Foundation

/// The Model Context Protocol face of the bridge: what `aa-mcp` speaks on stdio.
///
/// A translation layer and nothing more. Every tool is one bridge request, so every rule the host
/// enforces — ownership, authorization, one writer per conversation, bounded answers, the audit
/// log — holds for a voice assistant exactly as it does for the command line. Nothing here keeps
/// state between calls, and nothing here can reach a session the host would refuse.
///
/// The three tools that change a session — send, adopt, stop — take an `authorization` object and
/// are annotated destructive, so a client that asks its user before such calls will ask here. The
/// statement is the user's approval in their own words, and it is what the audit log records.
public final class MCPServer: @unchecked Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = "agent-warden"

    private let transport: (BridgeRequest) -> BridgeResponse
    private let sleep: (TimeInterval) -> Void

    public init(transport: @escaping (BridgeRequest) -> BridgeResponse,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.transport = transport
        self.sleep = sleep
    }

    /// One JSON-RPC message in, at most one out. Notifications get no answer.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(),
                           "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : error(id, -32600, "Invalid request")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return nil }      // notifications/initialized and friends

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { MCPServer.supportedVersions.contains($0) ? $0 : nil }
                ?? MCPServer.supportedVersions[0]
            return result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": MCPServer.serverName, "version": AgentAttentionVersion.string],
                "instructions": MCPServer.instructions,
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": MCPServer.tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return error(id, -32602, "tools/call needs a tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return result(id, call(name, arguments))
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    static let instructions = """
    Agent Warden watches the user's local Claude Code sessions and owns the ones it started or \
    adopted. Read tools are safe to call at any time. warden_send_prompt, warden_adopt_session and \
    warden_stop_session change a session: call them only after the user has explicitly approved that \
    specific action, and pass their approval, in their words, as authorization.statement. Sessions \
    the user runs in a terminal are observed, never written to; adopting one resumes its \
    conversation under Warden only after the terminal's own client has exited.
    """

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static let sessionID: [String: Any] = ["type": "string", "description": "The full session id."]
    private static let authorization: [String: Any] = [
        "type": "object",
        "description": "The user's explicit approval of this exact action.",
        "properties": [
            "confirmed": ["type": "boolean", "description": "True only if the user approved it."],
            "statement": ["type": "string", "maxLength": BridgeProtocol.maximumAuthorizationLength,
                          "description": "What the user approved, in their words."],
        ],
        "required": ["confirmed", "statement"],
        "additionalProperties": false,
    ]
    private static func annotations(readOnly: Bool, destructive: Bool = false,
                                    idempotent: Bool = true) -> [String: Any] {
        ["readOnlyHint": readOnly, "destructiveHint": destructive, "idempotentHint": idempotent,
         "openWorldHint": false]
    }

    static let tools: [[String: Any]] = [
        ["name": "warden_list_sessions",
         "description": "Every Claude Code session Warden can see: the ones it owns (can send to) and the ones it observes in terminals, with state, attention and who controls each.",
         "inputSchema": object([:]), "annotations": annotations(readOnly: true)],
        ["name": "warden_session_status",
         "description": "The current state of one session, owned or observed.",
         "inputSchema": object(["sessionId": sessionID], required: ["sessionId"]),
         "annotations": annotations(readOnly: true)],
        ["name": "warden_session_events",
         "description": "An owned session's event stream after a sequence number: acknowledgements, replies, tool use, results.",
         "inputSchema": object(["sessionId": sessionID,
                                "after": ["type": "integer", "minimum": 0, "description": "Resume after this sequence."]],
                               required: ["sessionId"]),
         "annotations": annotations(readOnly: true)],
        ["name": "warden_session_context",
         "description": "Bounded recent conversation of one session, read from its transcript only when Warden can verify whose it is.",
         "inputSchema": object(["sessionId": sessionID,
                                "maxMessages": ["type": "integer", "minimum": 1,
                                                "maximum": SessionContextReader.maximumMessages]],
                               required: ["sessionId"]),
         "annotations": annotations(readOnly: true)],
        ["name": "warden_session_summary",
         "description": "What one session is doing, as facts that each name their source and time. Use these facts; do not add to them.",
         "inputSchema": object(["sessionId": sessionID], required: ["sessionId"]),
         "annotations": annotations(readOnly: true)],
        ["name": "warden_focus_session",
         "description": "Bring a session's own terminal tab to the front: the tab Warden opened, or the tab the user linked. Exact tab or nothing.",
         "inputSchema": object(["sessionId": sessionID], required: ["sessionId"]),
         "annotations": annotations(readOnly: false)],
        ["name": "warden_start_session",
         "description": "Start a new Claude Code session Warden owns, in an approved project directory. Retrying with the same requestId returns the same session.",
         "inputSchema": object(["requestId": ["type": "string"], "cwd": ["type": "string"],
                                "model": ["type": "string"],
                                "terminal": ["type": "string", "enum": ["ghostty"],
                                             "description": "Open it in a new Ghostty tab the user can watch."]],
                               required: ["requestId", "cwd"]),
         // Destructive because it spawns a real Claude Code process that loads the project's own
         // `CLAUDE.md`, and because eight of them exhaust the session cap. `stop` needs approval to
         // end a process; saying `start` needs none to create one was the inconsistency.
         "annotations": annotations(readOnly: false, destructive: true)],
        ["name": "warden_send_prompt",
         "description": "Send a prompt to a session Warden owns, and wait briefly for the client to acknowledge receiving it. Requires the user's explicit approval. Retrying with the same messageId never sends twice.",
         "inputSchema": object(["sessionId": sessionID, "messageId": ["type": "string"],
                                "prompt": ["type": "string", "maxLength": BridgeProtocol.maximumPromptBytes],
                                "authorization": authorization,
                                "waitSeconds": ["type": "number", "minimum": 0, "maximum": 30,
                                                "description": "How long to wait for acknowledgement (default 10)."]],
                               required: ["sessionId", "messageId", "prompt", "authorization"]),
         "annotations": annotations(readOnly: false, destructive: true)],
        ["name": "warden_adopt_session",
         "description": "Take over a session the user started in a terminal, in steps: prepare (pin it; the user then exits Claude in that tab), complete (resume the same conversation under Warden once nothing else holds it), cancel. detach 'terminate' asks an idle original client to exit instead. Requires the user's explicit approval.",
         "inputSchema": object(["action": ["type": "string", "enum": ["prepare", "complete", "cancel"]],
                                "sessionId": sessionID, "requestId": ["type": "string"],
                                "detach": ["type": "string", "enum": ["user", "terminate"]],
                                "terminal": ["type": "string", "enum": ["ghostty"]],
                                "model": ["type": "string"],
                                "authorization": authorization],
                               required: ["action", "sessionId", "requestId", "authorization"]),
         "annotations": annotations(readOnly: false, destructive: true)],
        ["name": "warden_stop_session",
         "description": "Stop a session Warden owns. Requires the user's explicit approval. Never touches a session Warden only observes.",
         "inputSchema": object(["sessionId": sessionID, "authorization": authorization],
                               required: ["sessionId", "authorization"]),
         "annotations": annotations(readOnly: false, destructive: true)],
    ]

    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        func string(_ key: String) -> String? { arguments[key] as? String }
        func missing(_ key: String) -> [String: Any] { toolError("\(key) is required.") }
        /// A whole-number argument: absent, a number, or something that is neither.
        ///
        /// `as? Int` is not the gap it looks like — NSNumber bridging already takes `12`, `12.0`
        /// and `1e1`, so a client that spells an integer as a float is fine. What it cannot do is
        /// tell `12.7` or `"12"` apart from an argument that was never sent, and both used to land
        /// on `?? 0`. For an event cursor that is not a harmless default: zero means replay every
        /// event the session ever recorded, which is the one answer nobody asked for.
        func integer(_ key: String) -> (value: Int?, malformed: Bool) {
            guard let raw = arguments[key] else { return (nil, false) }
            guard let exact = raw as? Int else { return (nil, true) }
            return (exact, false)
        }
        func notWhole(_ key: String) -> [String: Any] { toolError("\(key) must be a whole number.") }
        let authorization = (arguments["authorization"] as? [String: Any]).map {
            BridgeAuthorization(confirmed: ($0["confirmed"] as? Bool) ?? false,
                                statement: ($0["statement"] as? String) ?? "", via: "mcp")
        }

        switch name {
        case "warden_list_sessions":
            return render(transport(.sessions))
        case "warden_session_status":
            guard let id = string("sessionId") else { return missing("sessionId") }
            return render(transport(.status(sessionID: id)))
        case "warden_session_events":
            guard let id = string("sessionId") else { return missing("sessionId") }
            let after = integer("after")
            if after.malformed { return notWhole("after") }
            return render(transport(.events(sessionID: id, afterSequence: after.value ?? 0)))
        case "warden_session_context":
            guard let id = string("sessionId") else { return missing("sessionId") }
            let limit = integer("maxMessages")
            if limit.malformed { return notWhole("maxMessages") }
            return render(transport(.context(sessionID: id, maxMessages: limit.value)))
        case "warden_session_summary":
            guard let id = string("sessionId") else { return missing("sessionId") }
            return render(transport(.summary(sessionID: id)))
        case "warden_focus_session":
            guard let id = string("sessionId") else { return missing("sessionId") }
            return render(transport(.focus(sessionID: id)))
        case "warden_start_session":
            guard let request = string("requestId") else { return missing("requestId") }
            guard let cwd = string("cwd") else { return missing("cwd") }
            return render(transport(.start(.init(requestID: request, cwd: cwd, model: string("model"),
                                                 terminal: string("terminal")))))
        case "warden_send_prompt":
            guard let id = string("sessionId") else { return missing("sessionId") }
            guard let message = string("messageId") else { return missing("messageId") }
            guard let prompt = string("prompt") else { return missing("prompt") }
            let wait = min(max((arguments["waitSeconds"] as? Double)
                               ?? (arguments["waitSeconds"] as? Int).map(Double.init) ?? 10, 0), 30)
            return sendAndAwaitAcknowledgement(id, message, prompt, authorization, wait)
        case "warden_adopt_session":
            guard let raw = string("action"), let action = BridgeRequest.AdoptRequest.Action(rawValue: raw) else {
                return toolError("action must be prepare, complete or cancel.")
            }
            guard let id = string("sessionId") else { return missing("sessionId") }
            guard let request = string("requestId") else { return missing("requestId") }
            var detach: BridgeRequest.AdoptRequest.Detach?
            if let raw = string("detach") {
                guard let value = BridgeRequest.AdoptRequest.Detach(rawValue: raw) else {
                    return toolError("detach must be user or terminate.")
                }
                detach = value
            }
            return render(transport(.adopt(.init(requestID: request, sessionID: id, action: action,
                                                 detach: detach, terminal: string("terminal"),
                                                 model: string("model"), authorization: authorization))))
        case "warden_stop_session":
            guard let id = string("sessionId") else { return missing("sessionId") }
            return render(transport(.stop(sessionID: id, authorization: authorization)))
        default:
            return toolError("Unknown tool \(name).")
        }
    }

    /// Send, then watch — bounded — for the client's own echo of this message. The answer says
    /// which of four things is true, and never promotes a pipe write to a delivery.
    private func sendAndAwaitAcknowledgement(_ sessionID: String, _ messageID: String, _ prompt: String,
                                             _ authorization: BridgeAuthorization?,
                                             _ wait: TimeInterval) -> [String: Any] {
        let sent = transport(.send(.init(sessionID: sessionID, messageID: messageID, prompt: prompt,
                                         authorization: authorization)))
        var latest = sent
        func phase(_ response: BridgeResponse) -> BridgeSessionPhase? {
            response.session?.messages.last { $0.messageID == messageID }?.phase
        }
        if sent.ok {
            let deadline = Date().addingTimeInterval(wait)
            while phase(latest) == .accepted, Date() < deadline {
                sleep(0.25)
                let status = transport(.status(sessionID: sessionID))
                if status.ok { latest = status } else { break }
            }
        }
        let delivery: String
        switch phase(latest) {
        case .clientAcknowledged?, .active?, .completed?: delivery = "acknowledged"
        case .failed?: delivery = "failed"
        case .uncertain?: delivery = "uncertain"
        case .accepted?: delivery = "notYetAcknowledged"
        default: delivery = sent.ok ? "unknown" : "notSent"
        }
        var body = MCPServer.dictionary(latest)
        if !sent.ok { body = MCPServer.dictionary(sent) }
        body["delivery"] = delivery
        return ["content": [["type": "text", "text": MCPServer.text(body)]],
                "structuredContent": body, "isError": !sent.ok]
    }

    private func render(_ response: BridgeResponse) -> [String: Any] {
        var body = MCPServer.dictionary(response)
        if response.observed != nil || response.sessions != nil, response.session == nil {
            body["sessionsByControl"] = MCPServer.controlList(response)
        }
        return ["content": [["type": "text", "text": MCPServer.text(body)]],
                "structuredContent": body, "isError": !response.ok]
    }

    /// One list for a voice assistant, with `control` on every row: `owned` rows can be sent to;
    /// `observed` ones cannot; `adopting` ones are part way through a handoff.
    static func controlList(_ response: BridgeResponse) -> [[String: Any]] {
        let owned = response.sessions ?? []
        let ownedIDs = Set(owned.map(\.sessionID))
        let adopting = Set((response.adoptions ?? []).filter {
            $0.phase != .adopted && $0.phase != .cancelled
        }.map(\.sessionID))
        var rows: [[String: Any]] = owned.map { state in
            ["sessionId": state.sessionID, "control": "owned", "phase": state.phase.rawValue,
             "cwd": state.cwd, "name": (state.cwd as NSString).lastPathComponent,
             "adopted": state.adoptedFrom != nil]
        }
        for row in response.observed ?? [] where !ownedIDs.contains(row.sessionID) {
            rows.append(["sessionId": row.sessionID,
                         "control": adopting.contains(row.sessionID) ? "adopting" : "observed",
                         "name": row.displayName, "state": row.state, "attention": row.attention,
                         "cwd": row.cwd, "process": row.process,
                         "linkedTab": row.link?.terminalID != nil])
        }
        return rows
    }

    private static func dictionary(_ response: BridgeResponse) -> [String: Any] {
        guard let data = try? JSONCoding.encoder.encode(response),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["ok": false]
        }
        return object
    }

    private static func text(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func result(_ id: Any, _ result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func error(_ id: Any?, _ code: Int, _ message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
