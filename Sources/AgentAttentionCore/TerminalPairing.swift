import Foundation

/// One Ghostty terminal, as Ghostty itself describes it.
///
/// Every field here comes from Ghostty's own scripting dictionary. Nothing is derived, guessed, or
/// assembled from a tty, a title or a working directory — a terminal id is Ghostty's to issue, and
/// inventing one would mean sending somebody to the wrong tab with full confidence.
public struct TerminalSnapshot: Codable, Sendable, Equatable {
    /// The stable id. This is the only field navigation ever uses.
    public var terminalID: String
    /// Shown to the user so they can recognise what they are about to link. Never matched on.
    public var tabID: String?
    public var windowID: String?
    public var name: String?
    public var workingDirectory: String?

    public init(terminalID: String, tabID: String? = nil, windowID: String? = nil,
                name: String? = nil, workingDirectory: String? = nil) {
        self.terminalID = terminalID
        self.tabID = tabID
        self.windowID = windowID
        self.name = name
        self.workingDirectory = workingDirectory
    }

    /// One line for the pairing window. Identifying, not decorative.
    public var summary: String {
        var parts = [name?.isEmpty == false ? name! : "(unnamed tab)"]
        if let workingDirectory, !workingDirectory.isEmpty { parts.append(workingDirectory) }
        parts.append("terminal \(terminalID)")
        return parts.joined(separator: "  ·  ")
    }
}

/// Why we could not do what was asked. Each of these is shown to the user as itself.
public enum GhosttyFailure: String, Codable, Sendable, Error {
    /// Ghostty is not running. We never start it.
    case notRunning
    /// macOS refused the Automation request, or the user declined it.
    case permissionDenied
    /// Ghostty is running but has no front window, tab or focused terminal to read.
    case noSelection
    /// The terminal id we were asked about no longer exists.
    case terminalMissing
    /// The script did not answer inside its budget.
    case timedOut
    /// Another scripting request is already outstanding in this process. Refused rather than
    /// queued, so nothing can fire long after the click that asked for it.
    case busy
    /// Ghostty answered something we could not parse.
    case unreadable
    /// No adapter is available at all (not macOS, or Ghostty is not installed).
    case unavailable

    public var explanation: String {
        switch self {
        case .notRunning: return "Ghostty is not running. Agent Warden never starts it."
        case .permissionDenied: return "macOS has not granted Agent Warden permission to talk to Ghostty."
        case .noSelection: return "Ghostty has no focused terminal to read — open or click a tab first."
        case .terminalMissing: return "That Ghostty tab no longer exists."
        case .timedOut: return "Ghostty did not answer in time."
        case .busy: return "Ghostty is still answering an earlier request. Nothing was sent — try again in a moment."
        case .unreadable: return "Ghostty's answer could not be read."
        case .unavailable: return "Ghostty scripting is not available here."
        }
    }
}

/// A running application, pinned to one incarnation of it.
///
/// The start time is what makes this useful. A pid on its own is recycled within hours; a pid *plus*
/// the moment that process started names one specific run of Ghostty, so a pairing made against
/// today's Ghostty cannot silently address a different one after a relaunch.
public struct ProcessFingerprint: Codable, Sendable, Equatable {
    public var pid: Int32
    public var startedAt: Double

    public init(pid: Int32, startedAt: Double) {
        self.pid = pid
        self.startedAt = startedAt
    }

    /// Same run, allowing for the coarse resolution of a reported start time.
    public func matches(_ other: ProcessFingerprint, tolerance: TimeInterval = 2.0) -> Bool {
        pid == other.pid && abs(startedAt - other.startedAt) <= tolerance
    }
}

/// What can be said about a session's link **without asking Ghostty anything**.
///
/// Deliberately offline. Validating a link properly means an Automation call, and doing that once
/// per row per redraw would be a stream of Apple events nobody asked for — and would make a picture
/// of the queue depend on a terminal answering. So this reads only what is already on disk and in
/// the session record, and says exactly that much:
///
/// - `none` — no link is saved;
/// - `saved` — a link is saved and still names this session's Claude process. **Saved is not
///   verified**: whether the tab still exists is only known after a navigation actually lands;
/// - `stale` — the saved link names a *different* Claude process than this session has now, so it
///   cannot be right. That is a fingerprint comparison, not a guess.
public enum SessionLinkState: String, Sendable, Equatable {
    case none
    case saved
    case stale

    /// `tolerance` matches `ProcessFingerprint.matches`: a start time a second or two apart is the
    /// same process; a different pid, or hours apart, is not.
    public static func of(pairing: TerminalPairing?,
                          identity: SessionIdentity,
                          tolerance: TimeInterval = 2.0) -> SessionLinkState {
        guard let pairing else { return .none }
        // A session whose own process is unidentified cannot be matched against anything. The link
        // is not shown as broken on the strength of something we simply do not know.
        guard let pid = identity.claudePID, let started = identity.claudePIDStartedAt else { return .saved }
        let sameProcess = pid == pairing.claudePID
            && abs(started - pairing.claudePIDStartedAt) <= tolerance
        return sameProcess ? .saved : .stale
    }
}

/// Everything the app is allowed to ask Ghostty.
///
/// Deliberately four read/focus operations and nothing else. Ghostty's dictionary also offers
/// `input text`, `send key`, `new tab`, `close` and `quit`; none of them is here, and nothing in
/// this app can reach them. Agent Warden looks and points. It does not type, open or close anything.
public protocol GhosttyControlling: Sendable {
    /// Which run of Ghostty is on screen right now, if any.
    func processIdentity() -> ProcessFingerprint?
    /// The terminal the user has selected: front window → selected tab → focused terminal.
    func readSelectedTerminal() -> Result<TerminalSnapshot, GhosttyFailure>
    /// Does this exact terminal id still exist?
    func terminalExists(id: String) -> Result<Bool, GhosttyFailure>
    /// Bring that exact terminal forward. No fallback, ever.
    func focus(terminalID: String) -> Result<Void, GhosttyFailure>
    /// Read back what is focused now, so a claim of success can be checked rather than assumed.
    func readFocusedTerminalID() -> Result<String, GhosttyFailure>
    /// Which application is frontmost. Focusing a terminal inside Ghostty does not bring Ghostty
    /// forward, so "the right tab is selected" is not the same as "you are looking at it".
    func frontmostApplicationPID() -> Int32?
    /// Every terminal Ghostty has, with the name each is showing right now.
    ///
    /// Only the handshake uses this, and only to find the one terminal answering to a token it just
    /// wrote. Names are never matched against a session's own name — see `TabHandshake`.
    func readAllTerminals() -> Result<[TerminalSnapshot], GhosttyFailure>
}

public extension GhosttyControlling {
    /// Default so an adapter that cannot tell simply says so, rather than claiming the front.
    func frontmostApplicationPID() -> Int32? { nil }
    /// Default so an adapter that cannot enumerate simply says so. A handshake against it then
    /// fails, and the session stays unlinked — which is the same place it was before.
    func readAllTerminals() -> Result<[TerminalSnapshot], GhosttyFailure> { .failure(.unavailable) }
}

// MARK: - The saved link

/// A link between one Claude Code session and one Ghostty terminal, made by the user.
///
/// Ghostty 1.3.1 exposes a terminal's id, name and working directory — but not its pid or tty. That
/// makes *matching* on a name or a directory a guess, and a guess here sends somebody to a
/// stranger's tab believing it is their own. It does not, however, make the question unanswerable:
/// writing a one-time token to the tty a session is actually running on, and asking Ghostty which
/// terminal is now called that, is a challenge only one terminal can answer. See `TabHandshake`.
///
/// So a link is evidence either way, and `provenance` says which kind: `userConfirmed` when a person
/// pointed at the tab, `derivedHandshake` when the terminal identified itself.
///
/// Both ends are pinned to a process incarnation. A recycled pid, a relaunched Ghostty or a
/// resumed-but-different session all invalidate the link rather than redirecting it.
public struct TerminalPairing: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    /// The full session id. Short ids collide, and a collision here is a wrong tab.
    public var sessionID: String
    public var claudePID: Int32
    public var claudePIDStartedAt: Double
    /// Recorded when known. A useful cross-check for the human; never used to find a tab.
    public var tty: String?

    public var terminalAppBundleID: String
    public var terminalAppPID: Int32
    public var terminalAppStartedAt: Double

    /// The only field navigation uses.
    public var terminalID: String
    /// Shown so the user recognises the link. Never matched on.
    public var tabID: String?
    public var windowID: String?
    public var terminalName: String?
    public var workingDirectory: String?

    public var pairedAt: Date
    public var lastVerifiedAt: Date?
    /// How this link came to exist. Only one value today, and it is the honest one.
    public var provenance: String

    public init(
        schema: Int = TerminalPairing.currentSchema,
        sessionID: String,
        claudePID: Int32,
        claudePIDStartedAt: Double,
        tty: String? = nil,
        terminalAppBundleID: String,
        terminalAppPID: Int32,
        terminalAppStartedAt: Double,
        terminalID: String,
        tabID: String? = nil,
        windowID: String? = nil,
        terminalName: String? = nil,
        workingDirectory: String? = nil,
        pairedAt: Date,
        lastVerifiedAt: Date? = nil,
        provenance: String = "userConfirmed"
    ) {
        self.schema = schema
        self.sessionID = sessionID
        self.claudePID = claudePID
        self.claudePIDStartedAt = claudePIDStartedAt
        self.tty = tty
        self.terminalAppBundleID = terminalAppBundleID
        self.terminalAppPID = terminalAppPID
        self.terminalAppStartedAt = terminalAppStartedAt
        self.terminalID = terminalID
        self.tabID = tabID
        self.windowID = windowID
        self.terminalName = terminalName
        self.workingDirectory = workingDirectory
        self.pairedAt = pairedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.provenance = provenance
    }

    public var claudeFingerprint: ProcessFingerprint {
        ProcessFingerprint(pid: claudePID, startedAt: claudePIDStartedAt)
    }

    public var terminalAppFingerprint: ProcessFingerprint {
        ProcessFingerprint(pid: terminalAppPID, startedAt: terminalAppStartedAt)
    }
}

/// What a saved link is worth right now.
public enum PairingVerdict: String, Sendable, Equatable {
    /// Both ends still name the same two processes, and the terminal is still there.
    case valid
    case none
    /// The session's Claude process is not the one that was paired — resumed, restarted, recycled.
    case sessionChanged
    /// Ghostty has been relaunched since the link was made.
    case terminalAppChanged
    case terminalAppNotRunning
    /// Ghostty is the same run, but that tab has gone.
    case terminalMissing
    /// We could not check. Not a licence to proceed.
    case inspectionDenied

    public var isUsable: Bool { self == .valid }

    /// What to tell the user, and what to do about it.
    public var explanation: String {
        switch self {
        case .valid: return "Linked to a Ghostty tab you confirmed."
        case .none: return "No Ghostty tab is linked to this session yet."
        case .sessionChanged:
            return "This session's Claude process is not the one that was linked. Link the tab again."
        case .terminalAppChanged:
            return "Ghostty has been restarted since this link was made, so the tab id no longer means the same thing. Link the tab again."
        case .terminalAppNotRunning:
            return "Ghostty is not running, so the linked tab cannot be checked."
        case .terminalMissing:
            return "The linked Ghostty tab no longer exists. Link the tab again."
        case .inspectionDenied:
            return "The link could not be checked — Ghostty did not answer, or permission was refused."
        }
    }
}

public enum PairingValidator {
    /// Judge a saved link against what is true now.
    ///
    /// Pure, and deliberately unforgiving. Every "changed" answer means *do not navigate*: a link
    /// that no longer names the same two processes is not a weaker link, it is a link to something
    /// else. There is no fallback to another terminal, and no re-derivation from cwd or title.
    public static func validate(
        pairing: TerminalPairing?,
        sessionPID: Int32?,
        sessionPIDStartedAt: Double?,
        ghostty: ProcessFingerprint?,
        terminalExists: Bool?
    ) -> PairingVerdict {
        guard let pairing else { return .none }
        guard let ghostty else { return .terminalAppNotRunning }
        guard ghostty.matches(pairing.terminalAppFingerprint) else { return .terminalAppChanged }

        // The session end. A missing or unverifiable pid is not a pass.
        guard let sessionPID, let sessionPIDStartedAt else { return .sessionChanged }
        let session = ProcessFingerprint(pid: sessionPID, startedAt: sessionPIDStartedAt)
        guard session.matches(pairing.claudeFingerprint) else { return .sessionChanged }

        guard let terminalExists else { return .inspectionDenied }
        return terminalExists ? .valid : .terminalMissing
    }
}


// MARK: - A stand-in for Ghostty

/// A stand-in for Ghostty, so every path can be exercised without touching the real application.
///
/// It ships here rather than in the tests because `--uicheck` drives the pairing window with it too.
/// What it cannot do is prove that focusing works: that is a live behaviour, only the person at the
/// machine can confirm it, and treating a passing mock as proof would be exactly the false
/// confidence this feature exists to avoid.
public final class MockGhostty: GhosttyControlling, @unchecked Sendable {
    public var fingerprint: ProcessFingerprint?
    public var selected: Result<TerminalSnapshot, GhosttyFailure>
    public var existing: Set<String>
    public var existsResult: Result<Bool, GhosttyFailure>?
    public var focusResult: Result<Void, GhosttyFailure>?
    /// What `readFocusedTerminalID` answers after a focus. Nil means "whatever was focused".
    public var focusedAfter: String?
    public var focusedResult: Result<String, GhosttyFailure>?

    public private(set) var focusCalls: [String] = []
    public private(set) var readSelectedCalls = 0
    /// How many times the focused terminal was read back. A landing has to be verified *after* any
    /// window was raised, not only before, so the count is part of what a check asserts.
    public private(set) var focusedReadCount = 0

    public init(
        fingerprint: ProcessFingerprint? = ProcessFingerprint(pid: 900, startedAt: 1000),
        selected: Result<TerminalSnapshot, GhosttyFailure> = .success(
            TerminalSnapshot(terminalID: "term-1", tabID: "tab-1", windowID: "win-1",
                             name: "red645-own-capital", workingDirectory: "/w/red645-own-capital")),
        existing: Set<String> = ["term-1"]
    ) {
        self.fingerprint = fingerprint
        self.selected = selected
        self.existing = existing
    }

    public func processIdentity() -> ProcessFingerprint? { fingerprint }

    /// Defaults to "Ghostty is frontmost", so a test has to opt into the awkward case.
    public var frontmostPID: Int32?
    public func frontmostApplicationPID() -> Int32? { frontmostPID ?? fingerprint?.pid }

    public func readSelectedTerminal() -> Result<TerminalSnapshot, GhosttyFailure> {
        readSelectedCalls += 1
        return selected
    }

    public func terminalExists(id: String) -> Result<Bool, GhosttyFailure> {
        existsResult ?? .success(existing.contains(id))
    }

    public func focus(terminalID: String) -> Result<Void, GhosttyFailure> {
        focusCalls.append(terminalID)
        if let focusResult { return focusResult }
        guard existing.contains(terminalID) else { return .failure(.terminalMissing) }
        focusedAfter = terminalID
        return .success(())
    }

    public func readFocusedTerminalID() -> Result<String, GhosttyFailure> {
        focusedReadCount += 1
        if let focusedResult { return focusedResult }
        guard let focusedAfter else { return .failure(.noSelection) }
        return .success(focusedAfter)
    }
}
