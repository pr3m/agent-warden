import Foundation

/// What a repository at a given directory says its branch is, right now.
///
/// Five outcomes, kept apart on purpose. "We could not look" and "there is no branch" are different
/// answers, and neither is "main".
public enum BranchReading: Sendable, Equatable {
    case branch(String)
    /// A real repository, but `HEAD` is not on a branch.
    case detached
    case notARepository
    /// The directory or its git data could not be read.
    case denied
    /// `git` did not answer inside the budget. It was killed; nothing was left running.
    case timedOut
    /// We did not look, or `git` is not installed.
    case unavailable

    public var name: String? {
        if case .branch(let name) = self { return name }
        return nil
    }

    public var rawValue: String {
        switch self {
        case .branch: return "branch"
        case .detached: return "detached"
        case .notARepository: return "notARepository"
        case .denied: return "denied"
        case .timedOut: return "timedOut"
        case .unavailable: return "unavailable"
        }
    }
}

/// A branch, and where the claim came from.
///
/// The source matters more than it looks. A session transcript stamps `gitBranch` when the session
/// starts and never revisits it, so a session that moved into a worktree afterwards carries the
/// branch it launched on — observed on this machine as five sessions all claiming `main` while their
/// working directories were on `dev/…` branches. A reading taken from the directory *now* is a
/// different kind of fact, and is labelled as one.
public struct BranchFact: Codable, Sendable, Equatable {
    /// "git" — read from the working directory just now. "transcript" — stamped at session start.
    public var source: String
    /// `branch`, `detached`, `notARepository`, `denied`, `timedOut`, `unavailable`.
    public var state: String
    public var branch: String?
    public var readAt: Date
    /// The directory the reading is about, so a stale fact cannot be pinned to a new one.
    public var path: String

    public init(source: String, state: String, branch: String?, readAt: Date, path: String) {
        self.source = source
        self.state = state
        self.branch = branch
        self.readAt = readAt
        self.path = path
    }

    public static func git(_ reading: BranchReading, path: String, at moment: Date) -> BranchFact {
        BranchFact(source: "git", state: reading.rawValue, branch: reading.name, readAt: moment, path: path)
    }

    public static func transcript(_ branch: String, path: String, at moment: Date) -> BranchFact {
        BranchFact(source: "transcript", state: "branch", branch: branch, readAt: moment, path: path)
    }

    /// Did we positively read a branch name?
    public var isResolved: Bool { branch?.isEmpty == false }

    /// One short line for a row or a Details entry. It never invents a name.
    public var summary: String {
        switch state {
        case "branch":
            let name = branch ?? "?"
            return source == "git" ? name : "\(name) (at launch)"
        case "detached": return "detached HEAD"
        case "notARepository": return "not a git repository"
        case "denied": return "branch unreadable (permission)"
        case "timedOut": return "branch unreadable (git did not answer)"
        default: return "branch unknown"
        }
    }
}

/// Reads the current branch of a working directory. Read-only, bounded, and off the main thread.
///
/// Discipline, because this runs `git` against the user's real repositories:
///
/// - **`branch --show-current` only.** It reads `HEAD`; it writes nothing, fetches nothing and
///   touches no remote.
/// - **`--no-optional-locks` and `GIT_OPTIONAL_LOCKS=0`**, so it cannot take the index lock and
///   cannot interfere with a `git` command the user is running in that same worktree.
/// - **`GIT_TERMINAL_PROMPT=0`** and no inherited stdin, so it can never sit waiting for input.
/// - **A hard timeout**, after which the process is terminated. A repository on a stalled network
///   mount answers `timedOut` rather than hanging the app.
/// - Arguments are passed as an argument vector, never through a shell, so a path containing
///   spaces, quotes or `$` is just a path.
///
/// The deadline, the concurrent pipe drain and the terminate-then-kill all live in
/// `BoundedProcess`, which is where they were written and where they are tested. They moved out of
/// this type once the power daemon's `pmset` calls needed the same three guarantees.
public enum GitBranchProbe {
    public static let defaultTimeout: TimeInterval = 2.0
    static let executable = "/usr/bin/git"

    /// Blocking. Callers run it on a background queue.
    public static func read(
        directory: String,
        timeout: TimeInterval = defaultTimeout,
        now: Date = Date()
    ) -> BranchFact {
        .git(reading(directory: directory, timeout: timeout), path: directory, at: now)
    }

    static func reading(directory: String, timeout: TimeInterval = defaultTimeout) -> BranchReading {
        guard !directory.isEmpty else { return .unavailable }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .denied }
        guard FileManager.default.isReadableFile(atPath: directory) else { return .denied }
        guard FileManager.default.isExecutableFile(atPath: executable) else { return .unavailable }

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"

        let outcome = BoundedProcess.run(
            executable: executable,
            arguments: ["-C", directory, "--no-optional-locks", "branch", "--show-current"],
            environment: environment,
            timeout: timeout
        )
        if outcome.launchFailed { return .unavailable }
        if outcome.timedOut { return .timedOut }
        return classify(status: outcome.status, stdout: outcome.stdout, stderr: outcome.stderr)
    }

    /// Separated so every outcome can be exercised without spawning anything.
    static func classify(status: Int32, stdout: Data, stderr: Data) -> BranchReading {
        let output = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = String(decoding: stderr, as: UTF8.self).lowercased()

        if status == 0 {
            // Exit 0 with nothing printed is what `--show-current` does on a detached HEAD.
            guard !output.isEmpty else { return .detached }
            guard let name = validBranchName(output) else { return .unavailable }
            return .branch(name)
        }
        if problem.contains("not a git repository") { return .notARepository }
        if problem.contains("permission denied") || problem.contains("cannot change to")
            || problem.contains("no such file or directory") { return .denied }
        if problem.contains("detached") { return .detached }
        return .unavailable
    }

    /// A branch name is one line of ordinary ref characters. Anything else is not shown.
    static func validBranchName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { return nil }
        guard !name.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@#"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return name
    }
}
