import Foundation

/// Starts a real Claude Code client, with the documented streaming interface and nothing else.
///
/// The command is fixed here rather than taken from a caller, so a bridge request can never turn
/// into an arbitrary process launch:
///
/// ```
/// claude --print --verbose --input-format stream-json --output-format stream-json
///        --replay-user-messages --permission-mode auto --permission-prompts none
///        --session-id <uuid> [--model <model>]
/// ```
///
/// `--replay-user-messages` is what makes acknowledgement observable at all: the client echoes each
/// user message back, so "it has the prompt" stops being an assumption about a pipe.
///
/// **Permissions are left alone.** `--dangerously-skip-permissions` and `bypassPermissions` are not
/// used and are not reachable from the protocol. If the client needs a decision this bridge cannot
/// answer, the turn says so rather than hanging or being waved through.
///
/// **Project instructions load through the client**, because the client is started in the directory
/// and reads its own `CLAUDE.md` as it always does. This host makes no claim about which files were
/// loaded — it only reports what the client itself says.
public struct ClaudeStreamLauncher: BridgeClientLaunching {
    public let executable: String
    /// Start the client with no tools and no MCP servers. Used by the disposable proof, so a benign
    /// test cannot touch anything even if the prompt were misread — rather than relying on the
    /// session's good behaviour. Project instructions still load; authentication is untouched.
    public let withoutTools: Bool

    public init(executable: String = ClaudeStreamLauncher.defaultExecutable,
                withoutTools: Bool = false) {
        self.executable = executable
        self.withoutTools = withoutTools
    }

    /// Where the CLI usually is. Overridable for a test, never guessed from a caller's input.
    public static var defaultExecutable: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }

    /// The whole command line, built in one place so it can be *read* by a test rather than
    /// inferred from a running process.
    ///
    /// `--permission-mode auto` is stated explicitly rather than left to whatever the default
    /// happens to be, so the mode a session runs under is a property of this file. It is the
    /// supported mode this user asked every session to run in. `--permission-prompts none` stays
    /// alongside it: nobody is at a keyboard here, so a prompt this bridge cannot answer must make
    /// the client refuse rather than hang. `--dangerously-skip-permissions` and `bypassPermissions`
    /// appear nowhere and are not reachable from the protocol.
    ///
    /// `resume` continues an existing conversation: `--resume <id>` in place of `--session-id`, and
    /// never `--fork-session`, which would quietly move the conversation to a new id and leave the
    /// adopted one behind.
    public static func arguments(sessionID: String, model: String?, withoutTools: Bool,
                                 resume: Bool = false) -> [String] {
        var arguments = [
            "--print",
            // Required: `--print` with stream-json output emits nothing useful without it.
            "--verbose",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--replay-user-messages",
            "--permission-mode", "auto",
            "--permission-prompts", "none",
            resume ? "--resume" : "--session-id", sessionID,
        ]
        if let model, !model.isEmpty { arguments += ["--model", model] }
        if withoutTools {
            // Explicit, not implied by the prompt.
            arguments += ["--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
        }
        return arguments
    }

    /// Markers a Claude Code session puts in the environment of everything it runs.
    ///
    /// A client that inherits them believes it is a child of that session: observed live, it
    /// announced "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker" and never
    /// appeared in the session registry. A host started from inside a session — or an app restarted
    /// by an agent — would then run every client it owns that way, and an adopted conversation
    /// would silently stop being saved. These are removed; the user's own `CLAUDE_CODE_*`
    /// settings are not.
    public static let inheritedSessionMarkers: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    ]

    /// The environment a client this host starts should see: this one, minus the markers above.
    public static func independentEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !inheritedSessionMarkers.contains($0.key) }
    }

    public func launch(sessionID: String,
                       cwd: String,
                       model: String?,
                       onLine: @escaping (String) -> Void,
                       onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        try run(sessionID: sessionID, cwd: cwd, model: model, resume: false,
                onLine: onLine, onExit: onExit)
    }

    public func resume(sessionID: String,
                       cwd: String,
                       model: String?,
                       onLine: @escaping (String) -> Void,
                       onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        try run(sessionID: sessionID, cwd: cwd, model: model, resume: true,
                onLine: onLine, onExit: onExit)
    }

    private func run(sessionID: String, cwd: String, model: String?, resume: Bool,
                     onLine: @escaping (String) -> Void,
                     onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        let arguments = ClaudeStreamLauncher.arguments(sessionID: sessionID, model: model,
                                                       withoutTools: withoutTools, resume: resume)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ClaudeStreamLauncher.independentEnvironment(ProcessInfo.processInfo.environment)

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // Exit is only reported once stdout has actually ended, so a result written just before
        // the process leaves is read rather than raced away.
        let drained = DispatchSemaphore(value: 0)
        let buffer = LineBuffer(onLine: onLine)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                buffer.flush()
                drained.signal()
                return
            }
            buffer.append(data)
        }
        // Read stderr too, or a client that fails to start dies silently behind a full pipe.
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                onLine("{\"type\":\"system\",\"subtype\":\"stderr\",\"text\":"
                       + (Self.jsonString(String(text.prefix(2_000)))) + "}")
            }
        }
        process.terminationHandler = { finished in
            // Wait — briefly, and bounded — for the output side to reach EOF before classifying the
            // exit. Tearing the reader down here is what loses a final result.
            DispatchQueue.global().async {
                _ = drained.wait(timeout: .now() + 5)
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                buffer.flush()
                onExit(finished.terminationStatus)
            }
        }

        // The bounded handle is built **before** the child exists. Bounding the input can fail, and
        // doing it afterwards meant a client was already running when it did — leaving a process to
        // be signalled and hoped about. Nothing is launched until the way to talk to it is ready.
        let handle = try ProcessHandle(process: process, input: input)
        try process.run()
        return handle
    }

    static func jsonString(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    /// One owned child process. `terminate` signals **this** process and nothing else.
    final class ProcessHandle: BridgeClientHandle, @unchecked Sendable {
        private let process: Process
        private let stdin: DescriptorGate
        /// How long a write may take before it is abandoned as ambiguous. A full pipe must not
        /// become a hang — for the writer, or for the cleanup waiting behind it.
        private let writeDeadline: TimeInterval

        /// Throws when the pipe cannot be made non-blocking.
        ///
        /// There is no quiet fallback to a blocking write here. A blocking write to a client that
        /// has stopped reading never returns, which turns one stuck prompt into a stuck host — so a
        /// client whose input cannot be bounded is refused at the door instead.
        init(process: Process, input: Pipe, writeDeadline: TimeInterval = 5) throws {
            self.process = process
            self.writeDeadline = writeDeadline
            self.stdin = try DescriptorGate(input.fileHandleForWriting, pipe: input)
        }

        var pid: Int32 { process.processIdentifier }
        var isRunning: Bool { process.isRunning }

        @discardableResult
        func write(line: String) -> Bool {
            guard process.isRunning, let data = (line + "\n").data(using: .utf8) else { return false }
            let deadline = Date().addingTimeInterval(writeDeadline)

            // The descriptor is *borrowed* for the whole write, and cannot be closed underneath it.
            // Reading the number out and writing to it later is the bug this replaces: between a
            // close on one thread and the next loop iteration on this one, the kernel is free to
            // give that number to the next pipe or socket opened anywhere in the process — and the
            // loop would carry on pushing an old prompt into it.
            let result = stdin.withDescriptor { descriptor -> Bool in
                var sent = 0
                return data.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    while sent < data.count {
                        // Checked every pass, so a terminate is honoured in milliseconds rather than
                        // holding the descriptor for the whole deadline.
                        if stdin.isClosing { return false }
                        if Date() >= deadline { return false }    // ambiguous, and the caller is told
                        let written = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
                        if written > 0 { sent += written; continue }
                        if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                            usleep(20_000)                        // the client is not reading yet
                            guard process.isRunning else { return false }
                            continue
                        }
                        if written < 0, errno == EINTR { continue }
                        return false
                    }
                    return true
                }
            }
            return result ?? false                                // nil: the pipe is already closed
        }

        func terminate() {
            // Two steps, and the order matters. The signal is immediate, so a write in progress
            // stops looping at once; the close waits for that writer to hand the descriptor back.
            // Cleanup never queues behind a full pipe, and the descriptor is never closed while
            // somebody is still writing to it.
            stdin.requestClose()
            stdin.closeWhenIdleAsynchronously()

            guard process.isRunning else { return }
            process.terminate()
            // A bounded grace period, then insist — and only ever on this pid, and only while it is
            // still the process we started.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

/// Ownership of one write descriptor, so its lifetime and its use cannot overlap.
///
/// A file descriptor is a small integer the kernel reuses the moment it is free. Closing one while
/// another thread still holds the number is not a use-after-free that crashes — it is a use-after-
/// free that *succeeds*, quietly, against whatever opened next. That is the whole reason this type
/// exists: the descriptor is borrowed under a lock held for the entire write, and the close takes
/// the same lock, so the number cannot be recycled underneath a writer.
///
/// Two locks, because they protect different things over different spans:
///
/// - `ownership` is held for as long as a borrow or a close lasts. It is the descriptor's lifetime.
/// - `state` is held for a few instructions at a time, for the flags. A terminate must be able to
///   say "stop" *while* a write is in progress, which it could not do if there were only one lock.
final class DescriptorGate: @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case cannotMakeNonBlocking(Int32)
        var errorDescription: String? {
            switch self {
            case .cannotMakeNonBlocking(let code):
                return "the client's input pipe could not be made non-blocking (errno \(code)); "
                     + "refusing to hold a client whose writes could not be bounded"
            }
        }
    }

    private let ownership = NSLock()
    private let state = NSLock()
    private let handle: FileHandle
    /// Held only so the pipe outlives the descriptor it owns.
    private let pipe: Pipe?
    private var closeRequested = false
    private var didClose = false

    init(_ handle: FileHandle, pipe: Pipe? = nil) throws {
        self.handle = handle
        self.pipe = pipe
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags != -1 else { throw Failure.cannotMakeNonBlocking(errno) }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw Failure.cannotMakeNonBlocking(errno)
        }
    }

    /// Has a close been asked for? Readable *during* a borrow, which is what makes a long write
    /// interruptible rather than something cleanup has to wait out.
    var isClosing: Bool {
        state.lock(); defer { state.unlock() }
        return closeRequested
    }

    var isClosed: Bool {
        state.lock(); defer { state.unlock() }
        return didClose
    }

    /// Signal, immediately. Takes no lock a writer could be holding, so it never waits.
    func requestClose() {
        state.lock(); closeRequested = true; state.unlock()
    }

    /// Borrow the descriptor. `nil` means it is gone — never a stale number.
    func withDescriptor<T>(_ body: (Int32) -> T) -> T? {
        ownership.lock(); defer { ownership.unlock() }
        state.lock()
        let gone = didClose
        state.unlock()
        guard !gone else { return nil }
        return body(handle.fileDescriptor)
    }

    /// Close once the current borrow has finished. Off the caller's thread, because a close on a
    /// full pipe can itself block.
    func closeWhenIdleAsynchronously() {
        DispatchQueue.global().async { [self] in closeWhenIdle() }
    }

    func closeWhenIdle() {
        ownership.lock(); defer { ownership.unlock() }
        state.lock()
        let already = didClose
        didClose = true
        closeRequested = true
        state.unlock()
        guard !already else { return }
        try? handle.close()
    }
}

/// Splits a byte stream into lines, bounded **while it scans** rather than after.
///
/// The previous version capped only the leftover tail, so a single enormous newline-terminated line
/// was accumulated and decoded in full before anything noticed. Now each line is measured as it is
/// found, and an oversized one is discarded through its newline so its tail cannot be read as a
/// frame of its own.
public final class LineBuffer: @unchecked Sendable {
    private let onLine: (String) -> Void
    private let lock = NSLock()
    private var pending = Data()
    private var discarding = false
    private let maximumLineBytes: Int

    public init(maximumLineBytes: Int = BridgeProtocol.maximumFrameBytes,
                onLine: @escaping (String) -> Void) {
        self.maximumLineBytes = maximumLineBytes
        self.onLine = onLine
    }

    public func append(_ data: Data) {
        lock.lock()
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                if discarding {
                    discarding = false                       // the rest of an oversized line: gone
                } else if !pending.isEmpty,
                          let text = String(data: pending, encoding: .utf8) {
                    lines.append(text)
                }
                pending.removeAll(keepingCapacity: true)
                continue
            }
            if discarding { continue }                       // still inside a line we refused
            if pending.count >= maximumLineBytes {
                pending.removeAll(keepingCapacity: false)
                discarding = true                            // and nothing of it is decoded
                continue
            }
            pending.append(byte)
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    public func flush() {
        lock.lock()
        let rest = discarding ? Data() : pending
        pending.removeAll()
        discarding = false
        lock.unlock()
        if let text = String(data: rest, encoding: .utf8), !text.isEmpty { onLine(text) }
    }
}
