import Foundation

/// Writing a terminal's title, through the tty a session is running on.
///
/// A seam, so the handshake below can be exercised without a terminal, a window server, or anybody's
/// title flickering.
public protocol TerminalTitleWriting: Sendable {
    /// Sets the title of whatever terminal owns `tty`. Answers whether the bytes were written —
    /// never whether any terminal acted on them, which is the question the handshake asks Ghostty.
    func setTitle(_ title: String, onTTY tty: String) -> Bool
}

/// The real one: an OSC sequence written to the device the session is attached to.
///
/// This is addressed to the *terminal emulator*, not to the program running in the tab. Claude Code
/// never sees it: OSC sequences are consumed by the terminal itself, so nothing is typed into a
/// session and no keystroke is simulated.
public struct OSCTitleWriter: TerminalTitleWriting {
    public init() {}

    public func setTitle(_ title: String, onTTY tty: String) -> Bool {
        // Only a real character device this user owns. A path that is not one is refused rather
        // than opened — writing to whatever happens to be at a given path is not a thing to do.
        var info = stat()
        guard tty.hasPrefix("/dev/"), stat(tty, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFCHR, info.st_uid == getuid() else { return false }

        // `O_NOCTTY` matters: without it this could adopt the session's terminal as its own.
        let descriptor = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // OSC 0 — icon name and window title, which is what Ghostty reports as a terminal's `name`.
        let sequence = "\u{1B}]0;\(title)\u{07}"
        let bytes = Array(sequence.utf8)
        let written = bytes.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
        return written == bytes.count
    }
}

/// Proving which Ghostty tab a session is in — rather than guessing, and rather than asking.
///
/// **What this replaces.** Ghostty exposes a terminal's id, name and working directory, but not its
/// pid or tty. So matching a session to a tab by its title or its directory is a guess, and a guess
/// here sends somebody to a stranger's tab with full confidence — which is why linking was a manual
/// step in the first place. Four tabs open in one repository is the ordinary case, not the corner
/// case, and a working directory cannot tell them apart.
///
/// **A challenge-response is not a guess.** Warden writes a one-time token as the title of the tty
/// the session is *actually running on*, then asks Ghostty which terminal is now called that. Only
/// the terminal that owns that tty can answer to it. The token is unique per attempt, so a stale
/// title cannot match, and the previous title is put straight back.
///
/// **What it will not do.** If no terminal answers, nothing is linked — a session in tmux, in
/// another terminal, or in no terminal at all simply has no link, exactly as before. It never falls
/// back to matching on a name or a directory, because that is the guess this exists to avoid.
public struct TabHandshake: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The session is not attached to a terminal device we can address.
        case noTTY
        /// The token could not be written to that device.
        case couldNotWrite
        /// Ghostty could not be asked.
        case ghostty(GhosttyFailure)
        /// Nobody answered to the token. The session is not in a Ghostty tab on this machine.
        case noTerminalAnswered
        /// More than one terminal claimed the token. Impossible by construction, and reported
        /// rather than resolved: linking one of them would be a coin toss.
        case ambiguous
    }

    private let titles: TerminalTitleWriting
    private let readAll: @Sendable () -> Result<[TerminalSnapshot], GhosttyFailure>
    private let attempts: Int
    private let pause: @Sendable (TimeInterval) -> Void
    private let interval: TimeInterval

    public init(titles: TerminalTitleWriting,
                readAll: @escaping @Sendable () -> Result<[TerminalSnapshot], GhosttyFailure>,
                attempts: Int = 10,
                interval: TimeInterval = 0.08,
                pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.titles = titles
        self.readAll = readAll
        self.attempts = max(1, attempts)
        self.interval = interval
        self.pause = pause
    }

    /// A token that cannot collide with a title anybody would choose, or with a previous attempt.
    public static func makeToken(_ uuid: String = UUID().uuidString) -> String {
        "⟦agent-warden:\(uuid)⟧"
    }

    /// Ask the terminal that owns `tty` to identify itself.
    ///
    /// On success the snapshot returned is the terminal **as it was before** the handshake — its own
    /// name, not the token — because that name is what the user recognises and what gets recorded.
    public func identifyTerminal(onTTY tty: String?,
                                 token: String = TabHandshake.makeToken())
        -> Result<TerminalSnapshot, Failure> {
        guard let tty, !tty.isEmpty, tty != "-" else { return .failure(.noTTY) }

        // Read first, so the title can be put back exactly as it was found.
        let before: [TerminalSnapshot]
        switch readAll() {
        case .failure(let failure): return .failure(.ghostty(failure))
        case .success(let list): before = list
        }
        // A token already on screen would mean a previous attempt left one behind. Refuse rather
        // than match it.
        guard !before.contains(where: { ($0.name ?? "").contains("⟦agent-warden:") }) else {
            return .failure(.ambiguous)
        }

        guard titles.setTitle(token, onTTY: tty) else { return .failure(.couldNotWrite) }

        var found: TerminalSnapshot?
        for attempt in 0..<attempts {
            if attempt > 0 { pause(interval) }
            switch readAll() {
            case .failure:
                continue                        // a transient refusal is not an answer either way
            case .success(let now):
                let claimants = now.filter { $0.name == token }
                if claimants.count > 1 {
                    restore(tty: tty, to: before, matching: claimants.first?.terminalID)
                    return .failure(.ambiguous)
                }
                if let one = claimants.first {
                    found = one
                    break
                }
            }
            if found != nil { break }
        }

        guard let found else {
            // Nothing answered. Put back whatever this tty had — we do not know which terminal it
            // was, so the best available is the title it is showing now, which is the token. Writing
            // an empty title hands control back to the shell, which sets its own on the next prompt.
            _ = titles.setTitle("", onTTY: tty)
            return .failure(.noTerminalAnswered)
        }

        restore(tty: tty, to: before, matching: found.terminalID)

        // Reported with the name it had before the handshake, not the token.
        let original = before.first { $0.terminalID == found.terminalID }
        return .success(TerminalSnapshot(terminalID: found.terminalID,
                                         tabID: found.tabID ?? original?.tabID,
                                         windowID: found.windowID ?? original?.windowID,
                                         name: original?.name,
                                         workingDirectory: found.workingDirectory
                                            ?? original?.workingDirectory))
    }

    /// Put the title back. An empty original means the shell owned it, and an empty title hands it
    /// back rather than inventing one.
    private func restore(tty: String, to before: [TerminalSnapshot], matching terminalID: String?) {
        let previous = before.first { $0.terminalID == terminalID }?.name ?? ""
        _ = titles.setTitle(previous, onTTY: tty)
    }
}
