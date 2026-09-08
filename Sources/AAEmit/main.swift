import Foundation
import AgentAttentionCore
#if canImport(Darwin)
import Darwin
#endif

// aa-emit — the Claude Code hook side of Agent Warden.
//
// Contract with Claude Code: read the hook payload on stdin, write nothing to stdout, exit 0.
// It must never block a session, never fail a hook, and never emit JSON that Claude Code would
// interpret as a decision. Every failure path below ends in exit(0).

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let paths = AppPaths.resolved(environment: environment)
let store = EventStore(paths: paths)

func finish(_ code: Int32 = 0) -> Never {
    exit(code)
}

// Insurance: whatever happens — a stalled stdin, a slow disk — this process is never the thing
// that holds up a coding session. Claude Code would kill it at its own timeout anyway; exiting
// first keeps the hook a non-event.
let watchdog = Thread {
    Thread.sleep(forTimeInterval: 3.0)
    exit(0)
}
watchdog.stackSize = 64 * 1024
watchdog.start()

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    let candidate = arguments[index + 1]
    return candidate.hasPrefix("--") ? nil : candidate
}

if arguments.contains("--version") {
    print("aa-emit \(AgentAttentionVersion.string)")
    finish()
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    aa-emit \(AgentAttentionVersion.string) — \(AgentAttentionVersion.displayName)'s Claude Code hook

    Reads a hook payload on stdin and records it for the app. Writes nothing to stdout.

      aa-emit                             classify from the payload
      aa-emit --signal <class>            state the class explicitly (recommended)
      aa-emit --kind <kind>               state the attention kind explicitly (implies attention)
      aa-emit --detail "<text>"           override the reason shown on the card
      aa-emit --dry-run                   print what would be written, write nothing
      aa-emit --doctor                    print paths, session identity and click-through plan
      aa-emit --version

      <class> : \(SignalClass.allCases.map(\.rawValue).joined(separator: " | "))
      <kind>  : \(AttentionKind.allCases.map(\.rawValue).joined(separator: " | "))

    The installed hook entries pass --signal/--kind, decided by Claude Code's own matcher, so
    normal operation does not depend on payload field names.

    Storage root: \(paths.root.path)   (override with AGENT_ATTENTION_HOME)
    """)
    finish()
}

// Read the payload. Claude Code closes stdin, so this returns promptly; a hook fired without a
// payload (manual test, doctor mode) still works because every field has a fallback.
func readPayload() -> [String: Any] {
    guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return [:] }
    guard let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty else { return [:] }
    // A PostToolUse payload can carry megabytes of tool output. Above a threshold we scan for the
    // few scalar fields we need rather than building a tree we would immediately discard.
    return ShallowJSON.payload(from: data, keys: HookTranslator.interestingKeys)
}

let payload = readPayload()

if arguments.contains("--doctor") {
    let identity = SessionIdentityBuilder.build(payload: payload, environment: environment, pid: getpid())
    let plan = TerminalTarget.plan(for: identity)
    print("""
    aa-emit doctor
      storage root      : \(paths.root.path)
      spool             : \(paths.spool.path)
      sessions          : \(paths.sessions.path)
      session id        : \(identity.sessionID)
      project           : \(identity.projectName)  (\(identity.cwd))
      claude pid        : \(identity.claudePID.map(String.init) ?? "not identified")
      pid started at    : \(identity.claudePIDStartedAt.map { String(format: "%.3f", $0) } ?? "-")
      tty               : \(identity.tty ?? "-")
      TERM_PROGRAM      : \(identity.termProgram ?? "-")
      terminal bundle   : \(identity.terminalAppPath ?? "not resolved")
      tmux pane         : \(identity.tmuxPane ?? "-")
      click-through     : \(plan.confidence.rawValue) — \(plan.explanation)
      resume fallback   : \(TerminalTarget.resumeCommand(for: identity))
      process ancestry  :
    """)
    for snap in ProcessProbe.ancestry(of: getpid()) {
        let path = ProcessProbe.executablePath(pid: snap.pid) ?? "-"
        print("        pid=\(snap.pid) ppid=\(snap.ppid) comm=\(snap.command) tty=\(snap.tty ?? "-") path=\(path)")
    }
    finish()
}

let override = HookIngestion.Override(
    signal: value(after: "--signal").flatMap(SignalClass.init(rawValue:)),
    kind: value(after: "--kind").flatMap(AttentionKind.init(rawValue:)),
    detail: value(after: "--detail")
)

let config = AttentionConfig.load(from: paths.configFile)
let identity = SessionIdentityBuilder.build(payload: payload, environment: environment, pid: getpid())
let outcome = HookIngestion.process(
    payload: payload,
    identity: identity,
    now: Date(),
    config: config,
    override: override
)

if arguments.contains("--dry-run") {
    let encoder = JSONCoding.encoder
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(outcome.heartbeat), let text = String(data: data, encoding: .utf8) {
        print("heartbeat:\n\(text)")
    }
    if let event = outcome.event, let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) {
        print("event:\n\(text)")
    } else {
        print("event: none (ordinary work)")
    }
    finish()
}

// Best effort, always quiet. A failed write is not worth interrupting a coding session over.
try? paths.createDirectories()
try? store.write(heartbeat: outcome.heartbeat)
if let event = outcome.event {
    try? store.write(event: event)
}

finish()
