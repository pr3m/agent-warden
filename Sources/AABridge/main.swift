import Foundation
import AgentAttentionCore

/// `aa-bridge` — the local interface for driving sessions **Agent Warden owns**.
///
/// Two halves of one binary. `serve` is the host: it owns a Unix socket, private to this user, and
/// the Claude Code sessions it started. Everything else is a client that sends one request to that
/// socket and prints the answer as JSON.
///
/// What it can do: start a *new* official Claude Code session in an approved directory, send it a
/// prompt, send a follow-up to the same session, read what happened, stop a session it started.
///
/// What it cannot do, and will refuse rather than fake: drive a session somebody already has open
/// in a terminal. Those are observed by Agent Warden and never driven — a session id this host did
/// not create is refused, because two things steering one conversation, with only one of them
/// visible to the person at the keyboard, is not a feature.

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// Prints the answer and exits with a status a caller can branch on: 0 for done, 3 for a refusal
/// that was understood, 4 for not knowing whether anything happened. Silence is never success.
func printJSON(_ response: BridgeResponse) -> Never {
    let encoder = JSONCoding.encoder
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    if response.ok { exit(0) }
    exit(response.error?.code == .clientUnavailable ? 4 : 3)
}

func answer(_ request: BridgeRequest) -> Never {
    printJSON((try? BridgeSocketClient.send(request, to: socketPath))
        ?? BridgeResponse(ok: false,
                          error: BridgeError(code: .clientUnavailable,
                                             message: "No bridge host answered at \(socketPath).")))
}

let paths = AppPaths.resolved()
let defaultSocket = paths.root.appendingPathComponent("bridge.sock").path

func value(_ name: String, default fallback: String? = nil) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else {
        return fallback
    }
    return arguments[index + 1]
}

let socketPath = value("socket", default: defaultSocket)!

if arguments.first == "--version" {
    print("aa-bridge \(AgentAttentionVersion.string)")
    exit(0)
}

guard let command = arguments.first, !command.hasPrefix("-") else {
    print("""
    aa-bridge — Agent Warden's local session bridge

      aa-bridge serve --approve <dir> [--approve <dir>…] [--socket <path>]
          Run the host. It owns the socket and every session it starts. Sessions may only be
          started inside an approved directory, and the list is empty unless you pass one.

      aa-bridge start  --cwd <dir> --request-id <id> [--model <name>] [--terminal ghostty]
          The session id is generated here. There is no way to name one, so this cannot be
          pointed at a session somebody already has open.

          Without --terminal the session runs in the background, exactly as it always has.
          With --terminal ghostty it opens in a NEW Ghostty tab you can watch: Claude runs in
          that tab, and the conversation is rendered there as it happens. Existing tabs are
          never reused or typed into.

          Typing in that tab is NOT enabled yet — Claude reads its input from Agent Warden, so
          keystrokes have nowhere to go. Send messages with `aa-bridge send`. The tab says so
          in its own header.

      aa-bridge focus  --session <uuid>
          Bring a visible session's own tab to the front, by the id Ghostty gave when it was
          created. No pairing step, and nothing else is touched.

      aa-bridge send   --session <uuid> --message-id <id> --prompt <text>
      aa-bridge status [--session <uuid>]
      aa-bridge events --session <uuid> [--after <sequence>]
      aa-bridge stop   --session <uuid>
          Answers `stopping` while the client is still up, and `stopped` once its exit has
          actually been seen. Asking is not the same as it having gone.

    Every answer is JSON. `--socket` defaults to \(defaultSocket).

    This drives only sessions this host started. A session opened in a terminal is observed by
    Agent Warden and is never driven from here.
    """)
    exit(0)
}

switch command {
case "serve":
    // Approved directories are explicit. No argument means no session may be started at all.
    var approved: [String] = []
    var index = 0
    while index < arguments.count {
        if arguments[index] == "--approve", index + 1 < arguments.count {
            approved.append(arguments[index + 1])
            index += 2
        } else {
            index += 1
        }
    }
    if approved.isEmpty {
        fail("aa-bridge serve: pass at least one --approve <dir>. Refusing to start a host that "
             + "would accept any directory.")
    }
    let executable = value("claude") ?? ClaudeStreamLauncher.defaultExecutable
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        fail("aa-bridge serve: no Claude Code executable at \(executable). Pass --claude <path>.")
    }

    // `--no-tools` is for the disposable proof: the client is started with no tools and no MCP
    // servers, so a benign test cannot touch anything regardless of what the prompt says.
    let withoutTools = arguments.contains("--no-tools")
    // The visible launcher needs the relay that runs in the tab. It sits beside this binary in the
    // app bundle; when it is not there, visible sessions are refused rather than silently becoming
    // background ones.
    // Found from the **running executable**, not from `argv[0]`. A shell may pass argv[0] as the
    // bare name it was typed as — `nohup aa-bridge serve …` does exactly that — and a bare name has
    // no directory to look beside, so the relay was not found and visible sessions were refused
    // with "this host cannot open visible sessions". A silent downgrade to a feature being missing,
    // caused by how the command happened to be invoked, is not a thing to leave in.
    let ownPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let relay = URL(fileURLWithPath: ownPath)
        .resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent("aa-session").path
    let visible: BridgeClientLaunching? = FileManager.default.isExecutableFile(atPath: relay)
        ? VisibleClaudeLauncher(surfaces: GhosttySurfaceAdapter(), root: paths.root,
                                claudeExecutable: executable, relayExecutable: relay,
                                withoutTools: withoutTools)
        : nil
    let host = BridgeHost(launcher: ClaudeStreamLauncher(executable: executable,
                                                         withoutTools: withoutTools),
                          approvedRoots: approved,
                          visibleLauncher: visible)
    let server = BridgeSocketServer(path: socketPath, host: host)
    do {
        try server.start()
    } catch {
        fail("aa-bridge serve: \(error.localizedDescription)")
    }
    FileHandle.standardError.write(Data("""
    aa-bridge host listening on \(socketPath)
    approved: \(approved.joined(separator: ", "))
    claude:   \(executable)

    """.utf8))

    // Stop only what this host started, on the way out. The sources are held for the life of the
    // process — the previous version let them go immediately, which left SIGTERM ignored with no
    // handler at all, so the host could not be stopped politely.
    var signalSources: [DispatchSourceSignal] = []
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            host.stopAll()
            server.stop()
            // Give the children a moment to go, then say plainly whether they did.
            let deadline = Date().addingTimeInterval(5)
            while host.hasRunningClients && Date() < deadline { usleep(100_000) }
            if host.hasRunningClients {
                FileHandle.standardError.write(Data("aa-bridge: some owned clients did not stop\n".utf8))
                exit(1)
            }
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    // A turn that has been out too long becomes `uncertain`. Nothing is ever resent.
    let uncertainAfter = TimeInterval(value("uncertain-after").flatMap(Double.init) ?? 300)
    let overdue = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
        host.markOverdue(after: uncertainAfter)
    }
    withExtendedLifetime((signalSources, overdue)) { RunLoop.main.run() }

case "start":
    guard let cwd = value("cwd") else { fail("aa-bridge start: --cwd is required") }
    guard let requestID = value("request-id") else { fail("aa-bridge start: --request-id is required") }
    // No caller-supplied session id: the host generates one, so this interface cannot be pointed
    // at a session somebody already has open.
    // Absent by default: the background client, unchanged. `--terminal ghostty` is the opt-in.
    let request = BridgeRequest.start(.init(requestID: requestID, cwd: cwd, model: value("model"),
                                            terminal: value("terminal")))
    answer(request)

case "send":
    guard let session = value("session") else { fail("aa-bridge send: --session is required") }
    guard let messageID = value("message-id") else { fail("aa-bridge send: --message-id is required") }
    guard let prompt = value("prompt") else { fail("aa-bridge send: --prompt is required") }
    answer(.send(.init(sessionID: session, messageID: messageID, prompt: prompt)))

case "status":
    answer(.status(sessionID: value("session")))

case "events":
    guard let session = value("session") else { fail("aa-bridge events: --session is required") }
    answer(.events(sessionID: session, afterSequence: Int(value("after") ?? "0") ?? 0))

case "focus":
    guard let session = value("session") else { fail("aa-bridge focus: --session is required") }
    // Handled by the host rather than by this client: only the host knows which terminal it
    // created, and that identity never leaves it.
    answer(.focus(sessionID: session))

case "stop":
    guard let session = value("session") else { fail("aa-bridge stop: --session is required") }
    answer(.stop(sessionID: session))

default:
    fail("aa-bridge: unknown command \(command)")
}
