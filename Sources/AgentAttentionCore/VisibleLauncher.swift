import Foundation

/// One terminal surface this app created, named by the ids Ghostty handed back.
///
/// All three are read back from the scripting API at creation. Nothing here is searched for,
/// matched by title, or inferred from a working directory — the ids are what the terminal itself
/// said, which is the difference between owning a surface and guessing at one.
public struct GhosttySurface: Codable, Sendable, Equatable {
    public var windowID: String
    public var tabID: String
    public var terminalID: String

    public init(windowID: String, tabID: String, terminalID: String) {
        self.windowID = windowID
        self.tabID = tabID
        self.terminalID = terminalID
    }
}

public enum GhosttySurfaceFailure: String, Error, Sendable, Equatable {
    /// Ghostty is not installed on this machine.
    case notInstalled
    /// macOS refused the Apple event. A permission this app asks for and does not work around.
    case permissionDenied
    /// The scripting call failed or answered something we could not read.
    case scriptingFailed
    /// The surface we were told about is not there.
    case surfaceGone
    /// Not a platform where any of this applies.
    case unsupportedPlatform
}

/// Creating and controlling **surfaces this app made**. A seam, so every rule can be tested without
/// a terminal opening on somebody's screen.
public protocol GhosttySurfaceCreating: Sendable {
    /// Create a new surface running the plan's command. Never reuses an existing terminal, and
    /// never sends keystrokes: the command is a property of a new surface configuration.
    func createSurface(_ plan: VisibleSessionPlan, inNewWindow: Bool)
        -> Result<GhosttySurface, GhosttySurfaceFailure>
    func surfaceExists(terminalID: String) -> Result<Bool, GhosttySurfaceFailure>
    func focus(terminalID: String) -> Result<Void, GhosttySurfaceFailure>
    func close(terminalID: String) -> Result<Void, GhosttySurfaceFailure>
    /// Is there a window to put a tab in? When not, one is created.
    func hasOpenWindow() -> Bool
}

public enum VisibleSessionError: Error, LocalizedError {
    case refusedPlan(String)
    case surface(GhosttySurfaceFailure)
    case channel(String)

    public var errorDescription: String? {
        switch self {
        case .refusedPlan(let why): return "This session could not be prepared: \(why)"
        case .surface(let failure):
            switch failure {
            case .notInstalled: return "Ghostty is not installed, so no visible session can be opened."
            case .permissionDenied:
                return "macOS refused Agent Warden permission to control Ghostty. Grant it in "
                     + "System Settings › Privacy & Security › Automation, then try again."
            case .scriptingFailed: return "Ghostty did not create the terminal."
            case .surfaceGone: return "The terminal Ghostty reported is already gone."
            case .unsupportedPlatform: return "Visible sessions need macOS and Ghostty."
            }
        case .channel(let why): return "The session channel could not be prepared: \(why)"
        }
    }
}

/// Starts a Claude Code client **inside a Ghostty tab the user can see**, and keeps talking to it.
///
/// The process genuinely runs on that tab's pty: Ghostty is asked to create a surface whose command
/// is Agent Warden's own relay, and the relay runs Claude as its child. It is not a view onto a
/// session living somewhere else — `claude attach` would be that, and its own help says the session
/// keeps running whether or not anybody is attached.
///
/// Two private channels carry the protocol. Warden writes stream-json into the inbox; the relay
/// reads it, feeds Claude, renders the conversation into the tab, and copies the raw frames back
/// out through the outbox. Both live in this host's own 0700 directory and are created 0600: a
/// session's prompts and replies are not for other local processes to read.
///
/// **Typing in that tab is not enabled.** Claude's standard input is the inbox, so keystrokes have
/// nowhere to go. The tab says so in its header rather than appearing to ignore the user.
public final class VisibleClaudeLauncher: BridgeClientLaunching {
    private let surfaces: GhosttySurfaceCreating
    private let root: URL
    private let claudeExecutable: String
    private let relayExecutable: String
    private let withoutTools: Bool

    public init(surfaces: GhosttySurfaceCreating, root: URL, claudeExecutable: String,
                relayExecutable: String, withoutTools: Bool = false) {
        self.surfaces = surfaces
        self.root = root
        self.claudeExecutable = claudeExecutable
        self.relayExecutable = relayExecutable
        self.withoutTools = withoutTools
    }

    public func launch(sessionID: String, cwd: String, model: String?,
                       onLine: @escaping (String) -> Void,
                       onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        // Both executables are checked to **exist** here, not merely to be well-shaped paths. A
        // command that cannot run still opens a terminal: Ghostty creates the surface, the command
        // fails instantly, the relay never opens its end of the pipe — and the reader below would
        // then block on that open for as long as the host lives, with the channel files left on
        // disk. Refusing early is the difference between a bounded failure and a leak.
        for executable in [relayExecutable, claudeExecutable] {
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw VisibleSessionError.refusedPlan(
                    "\(executable) is not an executable this host can run, so no terminal was opened")
            }
        }

        let channels = root.appendingPathComponent("visible", isDirectory: true)
        try? FileManager.default.createDirectory(at: channels, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let inbox = channels.appendingPathComponent("\(sessionID).in").path
        let outbox = channels.appendingPathComponent("\(sessionID).out").path

        // Validated **before** anything is created: the command is run by a shell, so a path that
        // is not a plain path is refused rather than quoted.
        guard let plan = VisibleSessionPlan(sessionID: sessionID, cwd: cwd, model: model,
                                            claudeExecutable: claudeExecutable,
                                            relayExecutable: relayExecutable,
                                            inbox: inbox, outbox: outbox,
                                            withoutTools: withoutTools) else {
            throw VisibleSessionError.refusedPlan(
                "the working directory, model or executable path is not a plain path this host "
                + "will put in a terminal command")
        }

        ScriptTrace.note("visible.launch", "session=\(sessionID) cwd=\(cwd)")
        let channel = try VisibleSessionChannel(inbox: inbox, outbox: outbox)
        do {
            // Asked before the tab is created, and asked once: the answer decides whether this
            // session joins the window the user already has or gets one of its own.
            let inNewWindow = !surfaces.hasOpenWindow()
            let surface = try ScriptTrace.step("visible.createSurface",
                                               detail: "inNewWindow=\(inNewWindow)",
                                               { surfaces.createSurface(plan, inNewWindow: inNewWindow) })
                .get()
            ScriptTrace.note("visible.surface", "terminal=\(surface.terminalID) window=\(surface.windowID)")
            return VisibleClaudeHandle(surface: surface, surfaces: surfaces, channel: channel,
                                       plan: plan, onLine: onLine, onExit: onExit)
        } catch {
            channel.remove()                  // nothing is left behind for a session that never ran
            throw VisibleSessionError.surface((error as? GhosttySurfaceFailure) ?? .scriptingFailed)
        }
    }
}

/// The two private files the relay and the host talk through.
final class VisibleSessionChannel: @unchecked Sendable {
    let inbox: String
    let outbox: String

    init(inbox: String, outbox: String) throws {
        self.inbox = inbox
        self.outbox = outbox
        for path in [inbox, outbox] {
            unlink(path)
            // 0600 from the moment it exists. A named pipe carrying a session's prompts is not
            // something other local processes have any business reading.
            guard mkfifo(path, 0o600) == 0 else {
                throw VisibleSessionError.channel("could not create \(path) (errno \(errno))")
            }
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO,
                  info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
                unlink(path)
                throw VisibleSessionError.channel("\(path) is not a private pipe owned by this user")
            }
        }
    }

    func remove() {
        unlink(inbox)
        unlink(outbox)
    }
}

/// One visible session: the surface it lives in, and the channel it speaks through.
public final class VisibleClaudeHandle: BridgeClientHandle, @unchecked Sendable {
    public let surface: GhosttySurface
    private let surfaces: GhosttySurfaceCreating
    private let channel: VisibleSessionChannel
    private let plan: VisibleSessionPlan
    private let onExit: (Int32) -> Void
    private let lock = NSLock()
    private var writer: FileHandle?
    private var stopped = false
    private var exitReported = false
    private var reader: Thread?
    /// Signalled when the client's stream ends — which is the only honest sign the process in the
    /// tab has actually finished.
    private let clientEnded = DispatchSemaphore(value: 0)

    init(surface: GhosttySurface, surfaces: GhosttySurfaceCreating,
         channel: VisibleSessionChannel, plan: VisibleSessionPlan,
         onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        self.surface = surface
        self.surfaces = surfaces
        self.channel = channel
        self.plan = plan
        self.onExit = onExit
        startReading(onLine: onLine)
    }

    /// The relay's pid is not ours to know; the surface is the thing this owns.
    public var pid: Int32 { 0 }

    /// Alive means **the surface is still there**. A tab the user closed took the session with it,
    /// and saying otherwise would leave a dead session looking live.
    public var isRunning: Bool {
        lock.lock(); let done = stopped; lock.unlock()
        if done { return false }
        return (try? surfaces.surfaceExists(terminalID: surface.terminalID).get()) ?? false
    }

    /// Bring the exact terminal this host created to the front. No pairing, no matching by title.
    @discardableResult
    public func focus() -> Bool {
        (try? surfaces.focus(terminalID: surface.terminalID).get()) != nil
    }

    @discardableResult
    public func write(line: String) -> Bool {
        lock.lock()
        if stopped { lock.unlock(); return false }
        if writer == nil {
            // Opened on first use: opening the write end of a pipe blocks until a reader arrives,
            // and the reader is the relay starting up in the tab.
            let descriptor = open(channel.inbox, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                var flags = fcntl(descriptor, F_GETFL, 0)
                flags &= ~O_NONBLOCK
                _ = fcntl(descriptor, F_SETFL, flags)
                writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            }
        }
        guard let writer else { lock.unlock(); return false }
        lock.unlock()
        guard let data = (line + "\n").data(using: .utf8) else { return false }
        do {
            try writer.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// Stop **this** session: the surface this host created, and the channel it made. Nothing else
    /// in Ghostty is touched.
    public func terminate() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let handle = writer
        writer = nil
        lock.unlock()

        // Closing our end of the inbox is what ends the client: the relay sees EOF, closes Claude's
        // standard input, Claude exits, and the relay exits with it.
        try? handle?.close()

        // **Wait for that to happen before touching the tab.** Ghostty asks the user "the terminal
        // still has a running process — close anyway?" whenever a surface is closed while something
        // is running in it. That dialog is modal: it blocks the window it belongs to, so the user
        // cannot even switch tabs until it is answered, and the scripting call returns *before* the
        // answer, so the close looks like it succeeded while the tab is still there. Letting the
        // client leave first means there is nothing for Ghostty to warn about, and the tab closes
        // silently — which is the only version of this that is safe to do to somebody's terminal.
        // Bounded tightly on purpose. Claude exits as soon as its standard input closes, so this is
        // normally over in well under a second; the deadline is here so that a client which will not
        // leave cannot hold a stop open. If it does expire, the close below still runs — and the
        // adapter checks afterwards whether the tab actually went, so a dialog left pending is
        // reported as a failed close rather than a clean stop.
        _ = clientEnded.wait(timeout: .now() + 1.5)
        let closed = surfaces.close(terminalID: surface.terminalID)
        channel.remove()
        switch closed {
        case .success:
            report(status: 0)
        case .failure:
            report(status: 1)
        }
    }

    /// Exactly once, from whichever end gets there first — the user closing the tab, Claude
    /// finishing, or a stop through the API.
    private func report(status: Int32) {
        lock.lock()
        if exitReported { lock.unlock(); return }
        exitReported = true
        lock.unlock()
        onExit(status)
    }

    private func startReading(onLine: @escaping (String) -> Void) {
        let path = channel.outbox
        let thread = Thread { [weak self] in
            // Opening for reading blocks until the relay opens the write end, which is what makes
            // this a handshake rather than a race.
            guard let file = FileHandle(forReadingAtPath: path) else { return }
            var buffer = Data()
            while true {
                let chunk = file.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let index = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: index)
                    buffer.removeSubrange(buffer.startIndex...index)
                    guard line.count <= BridgeProtocol.maximumFrameBytes,
                          let text = String(data: line, encoding: .utf8), !text.isEmpty else {
                        continue
                    }
                    onLine(text)
                }
                if buffer.count > BridgeProtocol.maximumFrameBytes { buffer.removeAll() }
                if self?.isStopped == true { break }
            }
            try? file.close()
            // The stream ended: Claude finished, or the user closed the tab. Either way this
            // session is over, and the host has to hear about it — the background launcher reports
            // its child's exit from the process itself, and a visible one that stayed silent would
            // leave a dead session with no exit status and an in-flight turn nothing could release.
            //
            // Zero, because what we have is the end of the stream rather than a status: the host
            // reads that as *uncertain* for anything still outstanding, which is what it is.
            self?.clientEnded.signal()
            self?.report(status: 0)
            self?.channel.remove()
        }
        thread.name = "warden.visible.reader"
        thread.start()
        reader = thread
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}
