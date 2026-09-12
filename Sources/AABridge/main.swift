import Foundation
import AgentAttentionCore

/// `aa-bridge` — the local interface for driving sessions **Agent Warden owns**.
///
/// Two halves of one binary. `serve` is the host: it owns a Unix socket, private to this user, and
/// the Claude Code sessions it started. Everything else is a client that sends one request to that
/// socket and prints the answer as JSON.
///
/// What it can do: start a *new* official Claude Code session in an approved directory, send it a
/// prompt, send a follow-up to the same session, read what happened, stop a session it owns; read
/// what Warden observes of the sessions in your terminals; and adopt one of those — which resumes
/// its conversation under Warden only after the terminal's own client has gone.
///
/// What it cannot do, and will refuse rather than fake: write to a session somebody has open in a
/// terminal. Two things steering one conversation, with only one of them visible to the person at
/// the keyboard, is not a feature.

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
let defaultSocket = paths.bridgeSocket.path

func value(_ name: String, default fallback: String? = nil) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else {
        return fallback
    }
    return arguments[index + 1]
}

/// `--authorize "<what the person approved>"`. Typing it is the person's approval, on the record.
func authorization() -> BridgeAuthorization? {
    value("authorize").map { BridgeAuthorization(confirmed: true, statement: $0, via: "cli") }
}

let socketPath = value("socket", default: defaultSocket)!

if arguments.first == "--version" {
    print("aa-bridge \(AgentAttentionVersion.string)")
    exit(0)
}

guard let command = arguments.first, !command.hasPrefix("-") else {
    print("""
    aa-bridge — Agent Warden's local session bridge

      aa-bridge serve [--approve <dir>…] [--roots-file <path>] [--socket <path>]
          Run the host. It owns the socket and every session it starts or adopts. Sessions may
          only be started or adopted inside an approved project directory: those passed with
          --approve, or — without any — the "approvedRoots" in \(paths.bridgeSettingsFile.path),
          read fresh on every request. No list means none. A root of /, your home directory or
          anything above it is ignored. The Agent Warden app runs one of these for you.
          Exits 75 when another host already holds the socket.

      aa-bridge start  --cwd <dir> --request-id <id> [--model <name>] [--terminal ghostty]
          The session id is generated here. There is no way to name one, so this cannot be
          pointed at a session somebody already has open. With --terminal ghostty it opens in a
          NEW Ghostty tab you can watch; typing in that tab is not enabled.

      aa-bridge send   --session <uuid> --message-id <id> --prompt <text> --authorize <statement>
      aa-bridge stop   --session <uuid> --authorize <statement>
          Both refuse without --authorize: a sentence saying what the person approved. It is
          written to \(paths.bridgeAuditLog.lastPathComponent) with the outcome; the prompt is not.

      aa-bridge sessions                                  owned and observed sessions, apart
      aa-bridge status  [--session <uuid>]                one session (owned or observed), or all owned
      aa-bridge events  --session <uuid> [--after <n>]    an owned session's event stream
      aa-bridge context --session <uuid> [--max <n>]      bounded recent conversation
      aa-bridge summary --session <uuid>                  what it is doing, each fact with its source
      aa-bridge focus   --session <uuid>                  its own tab: one Warden opened, or the tab
                                                          you linked (done by the app; exact or nothing)

      aa-bridge adopt prepare  --session <uuid> --request-id <id> --authorize <statement>
                               [--detach terminate]
      aa-bridge adopt complete --session <uuid> --request-id <id> --authorize <statement>
                               [--terminal ghostty] [--model <name>]
      aa-bridge adopt cancel   --session <uuid> --request-id <id> --authorize <statement>
          Take over a session you started in a terminal. prepare pins the exact conversation and
          process and says what must happen next — normally: type /exit in that tab. complete
          resumes the same conversation id under Warden, and only once no other process holds
          it. --detach terminate asks the original client to exit, once, and only while it is
          idle; it is never forced.

    Every answer is JSON. `--socket` defaults to \(defaultSocket).
    """)
    exit(0)
}

switch command {
case "serve":
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
    // Explicit either way: a list on the command line, or the user's own settings file, read on
    // every request. The file is never written by anything here.
    let rootsFile = value("roots-file").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? paths.bridgeSettingsFile
    let rootsProvider: (() -> [String])? = approved.isEmpty
        ? { BridgeSettings.load(from: rootsFile).approvedRoots }
        : nil
    let refused = approved.filter { BridgeSettings.acceptableRoots([$0]).isEmpty }
    if !refused.isEmpty {
        FileHandle.standardError.write(Data(("aa-bridge serve: ignoring approvals too broad to mean "
            + "one project: \(refused.joined(separator: ", "))\n").utf8))
    }
    let executable = value("claude") ?? ClaudeStreamLauncher.defaultExecutable
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        fail("aa-bridge serve: no Claude Code executable at \(executable). Pass --claude <path>.")
    }

    // `--no-tools` is for the disposable proof: the client is started with no tools and no MCP
    // servers, so a benign test cannot touch anything regardless of what the prompt says.
    let withoutTools = arguments.contains("--no-tools")
    // The relay that runs in a visible tab sits beside this binary in the app bundle. Found from
    // the **running executable**, not `argv[0]`: a shell may pass the bare name it was typed as,
    // which has no directory to look beside, and visible sessions were then refused for no reason
    // anybody could see.
    let ownPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let relay = URL(fileURLWithPath: ownPath)
        .resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent("aa-session").path
    let relayAvailable = FileManager.default.isExecutableFile(atPath: relay)
    let visible: BridgeClientLaunching? = relayAvailable
        ? VisibleClaudeLauncher(surfaces: GhosttySurfaceAdapter(), root: paths.root,
                                claudeExecutable: executable, relayExecutable: relay,
                                withoutTools: withoutTools)
        : nil
    let observed = WardenObservedSessions(paths: paths,
                                          relayExecutable: relayAvailable ? relay : nil,
                                          appControlSocket: paths.appControlSocket.path)
    let host = BridgeHost(launcher: ClaudeStreamLauncher(executable: executable,
                                                         withoutTools: withoutTools),
                          approvedRoots: approved,
                          visibleLauncher: visible,
                          rootsProvider: rootsProvider,
                          observed: observed,
                          audit: BridgeAuditLog(url: paths.bridgeAuditLog))
    let server = BridgeSocketServer(path: socketPath, host: host)
    do {
        try server.start()
    } catch BridgeSocketError.hostAlreadyRunning(let path) {
        // EX_TEMPFAIL: somebody else's host is live here. Not a crash, and nothing to fight over.
        fail("aa-bridge serve: a bridge host is already listening on \(path).", code: 75)
    } catch {
        fail("aa-bridge serve: \(error.localizedDescription)")
    }
    FileHandle.standardError.write(Data("""
    aa-bridge host listening on \(socketPath)
    approved: \(approved.isEmpty ? "from \(rootsFile.path), read per request" : approved.joined(separator: ", "))
    claude:   \(executable)

    """.utf8))

    // Stop only what this host owns, on the way out. The sources are held for the life of the
    // process — letting them go left SIGTERM ignored with no handler at all.
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
    answer(.start(.init(requestID: requestID, cwd: cwd, model: value("model"),
                        terminal: value("terminal"))))

case "send":
    guard let session = value("session") else { fail("aa-bridge send: --session is required") }
    guard let messageID = value("message-id") else { fail("aa-bridge send: --message-id is required") }
    guard let prompt = value("prompt") else { fail("aa-bridge send: --prompt is required") }
    answer(.send(.init(sessionID: session, messageID: messageID, prompt: prompt,
                       authorization: authorization())))

case "status":
    answer(.status(sessionID: value("session")))

case "sessions":
    answer(.sessions)

case "events":
    guard let session = value("session") else { fail("aa-bridge events: --session is required") }
    answer(.events(sessionID: session, afterSequence: Int(value("after") ?? "0") ?? 0))

case "context":
    guard let session = value("session") else { fail("aa-bridge context: --session is required") }
    answer(.context(sessionID: session, maxMessages: value("max").flatMap(Int.init)))

case "summary":
    guard let session = value("session") else { fail("aa-bridge summary: --session is required") }
    answer(.summary(sessionID: session))

case "focus":
    guard let session = value("session") else { fail("aa-bridge focus: --session is required") }
    // Handled by the host rather than by this client: only the host knows which terminal it
    // created, and only the app can validate a tab the user linked.
    answer(.focus(sessionID: session))

case "stop":
    guard let session = value("session") else { fail("aa-bridge stop: --session is required") }
    answer(.stop(sessionID: session, authorization: authorization()))

case "adopt":
    guard arguments.count > 1,
          let action = BridgeRequest.AdoptRequest.Action(rawValue: arguments[1]) else {
        fail("aa-bridge adopt: say prepare, complete or cancel")
    }
    guard let session = value("session") else { fail("aa-bridge adopt: --session is required") }
    guard let requestID = value("request-id") else { fail("aa-bridge adopt: --request-id is required") }
    let detach = value("detach").map { BridgeRequest.AdoptRequest.Detach(rawValue: $0) }
    if let detach, detach == nil { fail("aa-bridge adopt: --detach is user or terminate") }
    answer(.adopt(.init(requestID: requestID, sessionID: session, action: action,
                        detach: detach ?? nil, terminal: value("terminal"), model: value("model"),
                        authorization: authorization())))

default:
    fail("aa-bridge: unknown command \(command)")
}
