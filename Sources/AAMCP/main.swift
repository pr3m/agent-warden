import Foundation
import AgentAttentionCore

/// `aa-mcp` — Agent Warden's sessions, as a local MCP server on stdio.
///
/// Every tool call becomes one request to the bridge host's private socket; this process holds no
/// state and has no authority of its own. With no host running it still answers — every tool then
/// says the host is unavailable — so a client can tell "Warden is not running" from "Warden said no".

let arguments = Array(CommandLine.arguments.dropFirst())
let paths = AppPaths.resolved()

func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let socketPath = value("socket") ?? paths.bridgeSocket.path
let ownPath = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    .resolvingSymlinksInPath().path

if arguments.contains("--version") {
    print("aa-mcp \(AgentAttentionVersion.string)")
    exit(0)
}

if arguments.contains("--print-config") {
    // What a local MCP client needs to launch this. Printed, never written into anybody's config.
    let config: [String: Any] = ["mcpServers": [MCPServer.serverName: [
        "type": "stdio", "command": ownPath, "args": [String](),
    ]]]
    let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys,
                                                                            .withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    aa-mcp — Agent Warden's sessions as a local MCP server (stdio, JSON-RPC 2.0)

      aa-mcp                   serve on stdin/stdout; the bridge host at \(socketPath)
      aa-mcp --socket <path>   another host socket
      aa-mcp --print-config    the JSON a local MCP client needs to launch this

    Tools: warden_list_sessions, warden_session_status, warden_session_events,
    warden_session_context, warden_session_summary, warden_focus_session, warden_start_session,
    and — with the user's explicit approval as `authorization` — warden_send_prompt,
    warden_adopt_session, warden_stop_session.
    """)
    exit(0)
}

signal(SIGPIPE, SIG_IGN)
let server = MCPServer(transport: { request in
    (try? BridgeSocketClient.send(request, to: socketPath))
        ?? BridgeResponse(ok: false, error: BridgeError(
            code: .clientUnavailable,
            message: "No Agent Warden bridge host answered at \(socketPath). Is the app running?"))
})

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let reply = server.handle(line: line) {
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
}
