import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A snapshot of one BSD process, read through `sysctl(KERN_PROC_PID)`.
public struct ProcSnapshot: Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32
    /// Epoch seconds. Combined with the pid this identifies a process across PID reuse.
    public let startedAt: Double
    /// Short command name (`p_comm`, 16 chars max).
    public let command: String
    /// Controlling terminal, e.g. "/dev/ttys004", when the process has one.
    public let tty: String?
}

/// The outcome of asking the kernel about one process.
public enum ProcInspection: Sendable, Equatable {
    case found(ProcSnapshot)
    /// The kernel answered, and there is no such process.
    case notFound
    /// We were refused, or inspection is unavailable here. Nothing is claimed.
    case denied
}

/// Read-only inspection of the local process tree. Used by the hook emitter to work out which
/// Claude Code process and which terminal a hook fired from, and by the app to check liveness.
public enum ProcessProbe {
    #if canImport(Darwin)

    /// Can we inspect processes at all in this context?
    ///
    /// A sandboxed caller (a review tool, a restricted profile) may be refused `sysctl` entirely.
    /// Asking about ourselves is the cheapest way to find out, and the answer decides whether a
    /// failed lookup means "gone" or "not allowed to look".
    public static let inspectionIsAvailable: Bool = {
        if case .found = inspect(pid: getpid()) { return true }
        return false
    }()

    public static func inspect(pid: Int32) -> ProcInspection {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        errno = 0
        let result = sysctl(&mib, 4, &info, &size, nil, 0)

        if result != 0 {
            switch errno {
            case ESRCH, ENOENT:
                return .notFound
            default:
                // EPERM, EACCES, EINVAL under a sandbox, anything else: we do not know.
                return .denied
            }
        }
        // A pid that no longer exists answers successfully with an empty record.
        guard size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
            return .notFound
        }

        let started = Double(info.kp_proc.p_un.__p_starttime.tv_sec)
            + Double(info.kp_proc.p_un.__p_starttime.tv_usec) / 1_000_000

        let commBuffer = info.kp_proc.p_comm
        let commSize = MemoryLayout.size(ofValue: commBuffer)
        let command = withUnsafeBytes(of: commBuffer) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return base.withMemoryRebound(to: CChar.self, capacity: commSize) { String(cString: $0) }
        }

        var tty: String?
        let dev = info.kp_eproc.e_tdev
        if dev != -1, let name = devname(dev, S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }

        return .found(ProcSnapshot(
            pid: info.kp_proc.p_pid,
            ppid: info.kp_eproc.e_ppid,
            startedAt: started,
            command: command,
            tty: tty
        ))
    }

    public static func snapshot(pid: Int32) -> ProcSnapshot? {
        if case .found(let snap) = inspect(pid: pid) { return snap }
        return nil
    }

    /// Absolute executable path, e.g. "/Applications/Ghostty.app/Contents/MacOS/ghostty".
    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func isAlive(pid: Int32) -> Bool {
        snapshot(pid: pid) != nil
    }
    #else
    public static let inspectionIsAvailable = false
    public static func inspect(pid: Int32) -> ProcInspection { .denied }
    public static func snapshot(pid: Int32) -> ProcSnapshot? { nil }
    public static func executablePath(pid: Int32) -> String? { nil }
    public static func isAlive(pid: Int32) -> Bool { false }
    #endif

    /// Walk up from `pid` to pid 1, newest first. Bounded so a cycle cannot hang the emitter.
    public static func ancestry(of pid: Int32, limit: Int = 24) -> [ProcSnapshot] {
        var chain: [ProcSnapshot] = []
        var current = pid
        var seen = Set<Int32>()
        while current > 1, chain.count < limit, !seen.contains(current) {
            seen.insert(current)
            guard let snap = snapshot(pid: current) else { break }
            chain.append(snap)
            current = snap.ppid
        }
        return chain
    }

    /// Whether an ancestor is the Claude Code CLI.
    ///
    /// The short command name is not enough: a released CLI lives at
    /// `~/.local/share/claude/versions/<version>`, so `p_comm` reads as the version number and a
    /// name-only heuristic finds nothing. The executable path is the reliable signal.
    ///
    /// Every rule here is a *positive* identification. A loose "the path mentions claude
    /// somewhere" rule was removed deliberately: a shell started in a directory called `claude`
    /// would have matched it, and everything downstream — liveness, stall inference — is a claim
    /// about a specific process. Where we cannot identify one, the answer is `nil`, not a guess.
    public static func looksLikeClaude(command: String, executablePath: String?) -> Bool {
        if command == "claude" || command == "claude-code" { return true }
        guard let path = executablePath?.lowercased() else { return false }
        let basename = (path as NSString).lastPathComponent
        if basename == "claude" || basename == "claude-code" { return true }
        // Released CLI: ~/.local/share/claude/versions/<version>
        if path.contains("/claude/versions/") { return true }
        // npm/bun install: …/node_modules/@anthropic-ai/claude-code/cli.js and friends. The
        // interpreter runs it, so the argument path is what identifies it — but `proc_pidpath`
        // reports the interpreter, not the script, so this only fires when the launcher itself
        // lives inside the package directory.
        if path.contains("/@anthropic-ai/claude-code/") { return true }
        if path.contains("/claude-code/") { return true }
        return false
    }

    /// Known terminal executables, matched against the `.app` bundle path.
    static let terminalBundleHints: [String] = [
        "Ghostty.app", "iTerm.app", "Terminal.app", "WezTerm.app", "Alacritty.app",
        "kitty.app", "Warp.app", "Hyper.app", "Visual Studio Code.app", "Code.app",
        "Cursor.app", "Tabby.app", "Rio.app",
    ]

    /// Best-effort answer to "which claude process, on which tty, inside which terminal app".
    public static func locateSession(from pid: Int32) -> (claude: ProcSnapshot?, terminalAppPath: String?) {
        let chain = ancestry(of: pid)
        var claude: ProcSnapshot?
        var terminalPath: String?

        for snap in chain {
            let path = executablePath(pid: snap.pid)
            if claude == nil, looksLikeClaude(command: snap.command, executablePath: path) {
                claude = snap
            }
            if terminalPath == nil, let path {
                if let hit = terminalBundleHints.first(where: { path.contains("/" + $0 + "/") }),
                   let range = path.range(of: "/" + hit) {
                    terminalPath = String(path[path.startIndex..<range.upperBound])
                }
            }
        }

        // Deliberately no fallback. The previous "first ancestor that owns a tty" rule would
        // happily settle on the transient shell that ran the hook, or on a long-lived unrelated
        // login shell — and then report a dead session as alive, or a live one as gone. An
        // unidentified process is reported as unidentified.
        return (claude, terminalPath)
    }
}
