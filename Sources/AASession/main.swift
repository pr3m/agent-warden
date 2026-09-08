import Foundation
import AgentAttentionCore

/// `aa-session` — the process that lives in the Ghostty tab.
///
/// Agent Warden asks Ghostty to create a surface whose command is this program. It then runs the
/// official Claude Code client **as its own child, on that tab's pty**, so the session genuinely
/// belongs to the terminal you are looking at rather than being a view onto something running
/// elsewhere.
///
/// It does three things and nothing else:
///
/// - feeds Claude the stream-json Warden writes into a private inbox pipe,
/// - copies Claude's raw frames back out through a private outbox pipe, so Warden keeps exact
///   message correlation,
/// - renders those frames into a readable transcript for the person watching the tab.
///
/// **Typing here is not enabled.** Claude's standard input is the inbox, so keystrokes have
/// nowhere to go; the header says so rather than letting the tab look broken.

let arguments = Array(CommandLine.arguments.dropFirst())

func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("aa-session: " + message + "\n").utf8))
    exit(2)
}

if arguments.first == "--version" {
    print("aa-session \(AgentAttentionVersion.string)")
    exit(0)
}
if arguments.isEmpty || arguments.contains("--help") {
    print("""
    aa-session \(AgentAttentionVersion.string) — the Agent Warden session that runs in your terminal

      aa-session --session-id <uuid> --cwd <dir> --claude <path>
                 --inbox <pipe> --outbox <pipe> [--model <name>] [--no-tools]

    Started by `aa-bridge start --terminal ghostty`. It runs Claude Code here, in this tab, and
    relays Agent Warden's messages to it. It is not meant to be run by hand.
    """)
    exit(0)
}

guard let sessionID = value("session-id"), let cwd = value("cwd"),
      let claude = value("claude"), let inbox = value("inbox"), let outbox = value("outbox") else {
    fail("missing one of --session-id, --cwd, --claude, --inbox, --outbox")
}
let model = value("model")

// The channel has to be ours: a private pipe, owned by this user. Anything else and this refuses
// rather than reading a session's traffic out of a file somebody else can write.
for path in [inbox, outbox] {
    var info = stat()
    guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO,
          info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
        fail("\(path) is not a private pipe owned by this user")
    }
}
guard FileManager.default.isExecutableFile(atPath: claude) else {
    fail("no Claude Code executable at \(claude)")
}

/// Everything the background reader touches, in one place that is **not** main-actor isolated.
///
/// Top-level code in `main.swift` is implicitly `@MainActor` under Swift 6. Claude's stdout is read
/// by a `readabilityHandler`, which runs on a Dispatch queue, so the moment that handler called a
/// top-level function or read a top-level `let`, the runtime isolation check failed and the process
/// died with `SIGTRAP` — `dispatch_assert_queue` inside `swift_task_isCurrentExecutor`. It was not
/// a hang and not an error anybody saw: the tab opened, printed its header, and the relay was gone
/// by the time Claude's first line arrived. Holding the outbox, the renderer and the writing here,
/// behind a lock, is what makes that handler legal as well as correct.
final class TranscriptSink: @unchecked Sendable {
    private let relay: FileHandle
    private let renderer = TranscriptRenderer()
    private let lock = NSLock()

    init(relay: FileHandle) { self.relay = relay }

    /// One frame, two audiences: raw to Warden, rendered to the person. Neither gets the other's
    /// version, and the two writes cannot interleave with another line's.
    func receive(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if let data = (line + "\n").data(using: .utf8) { try? relay.write(contentsOf: data) }
        TranscriptSink.emit(renderer.render(line: line))
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? relay.close()
    }

    /// Writing to the tab. Static and capture-free, so it is callable from any thread.
    static func emit(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}

func show(_ lines: [String]) { TranscriptSink.emit(lines) }

show(TranscriptRenderer.header(sessionID: sessionID, cwd: cwd, model: model))

// The client, with the same fixed argument list the background launcher uses — including the
// user's Auto permission mode, and no way to reach a bypass flag from here.
let process = Process()
process.executableURL = URL(fileURLWithPath: claude)
process.arguments = ClaudeStreamLauncher.arguments(sessionID: sessionID, model: model,
                                                   withoutTools: arguments.contains("--no-tools"))
process.currentDirectoryURL = URL(fileURLWithPath: cwd)

let input = Pipe()
let output = Pipe()
process.standardInput = input
process.standardOutput = output
process.standardError = Pipe()

// Warden's frames go back out through the outbox. Opening it blocks until Warden opens its read
// end, which is the handshake: neither side proceeds until both are there.
guard let relay = FileHandle(forWritingAtPath: outbox) else {
    fail("could not open the outbox pipe")
}

// `nonisolated(unsafe)` on purpose, and safe for a stated reason: everything below is either
// internally synchronised (`TranscriptSink`, `LineBuffer`) or already thread-safe
// (`DispatchSemaphore`). Without it these are main-actor-isolated top-level bindings, and the
// Dispatch queue that reads Claude's output may not touch them at all.
nonisolated(unsafe) let sink = TranscriptSink(relay: relay)
nonisolated(unsafe) let finished = DispatchSemaphore(value: 0)
// `@Sendable` is what actually makes this closure nonisolated. A closure written at top level in
// `main.swift` inherits that file's implicit `@MainActor`, whatever the binding it is stored in is
// annotated with — which is why marking the *variable* nonisolated changed nothing and the process
// still trapped on the first line Claude produced.
nonisolated(unsafe) let buffer = LineBuffer { @Sendable line in sink.receive(line) }
output.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    if data.isEmpty {
        handle.readabilityHandler = nil
        buffer.flush()
        finished.signal()
        return
    }
    buffer.append(data)
}

do {
    try process.run()
} catch {
    // Sanitised like everything else that reaches this terminal. The rule is "nothing is written
    // raw", not "nothing a model wrote is written raw" — an exception is how the rule gets lost.
    show(["", "  ✘ Claude Code could not be started: "
              + TranscriptRenderer.safe(error.localizedDescription), ""])
    sink.close()
    exit(3)
}

// Warden's prompts arrive on the inbox and are handed straight to Claude. Nothing here reads the
// keyboard: this tab is driven by the API, and the header says so.
let feeder = Thread {
    guard let source = FileHandle(forReadingAtPath: inbox) else { return }
    while true {
        let chunk = source.availableData
        if chunk.isEmpty { break }
        try? input.fileHandleForWriting.write(contentsOf: chunk)
    }
    try? source.close()
    try? input.fileHandleForWriting.close()
}
feeder.name = "warden.session.feeder"
feeder.start()

process.waitUntilExit()
_ = finished.wait(timeout: .now() + 5)
sink.close()

let status = process.terminationStatus
show(["", status == 0 ? "  ─ session ended ─" : "  ✘ session ended with status \(status)", ""])
exit(status)
