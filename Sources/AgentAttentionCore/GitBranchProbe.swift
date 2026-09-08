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
/// working directories were on `cs/…` branches. A reading taken from the directory *now* is a
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

        let outcome = runBounded(
            executable: executable,
            arguments: ["-C", directory, "--no-optional-locks", "branch", "--show-current"],
            environment: environment,
            timeout: timeout
        )
        if outcome.launchFailed { return .unavailable }
        if outcome.timedOut { return .timedOut }
        return classify(status: outcome.status, stdout: outcome.stdout, stderr: outcome.stderr)
    }

    /// What a bounded run produced.
    public struct ProcessOutcome: Sendable, Equatable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        public var timedOut: Bool
        public var launchFailed: Bool
        /// True when the child printed more than we were willing to hold. The excess was read and
        /// thrown away, so the child never blocks on a full pipe.
        public var outputTruncated: Bool
    }

    /// Run a child process with a deadline that is actually enforced, and pipes that cannot deadlock.
    ///
    /// Three things have to be true at once, and getting any of them wrong makes the timeout a
    /// decoration:
    ///
    /// - **The deadline starts before the child does.** Anything measured after a blocking read is
    ///   measuring the wrong thing.
    /// - **Both pipes drain concurrently**, via readability handlers. Reading stdout to the end and
    ///   *then* stderr deadlocks the moment the child fills stderr while we wait on stdout — and
    ///   reading "to the end" of a hung child never returns at all, so no later deadline can help.
    /// - **Output is bounded**, but the excess is still read and discarded rather than left in the
    ///   pipe. A child blocked writing into a full pipe is a child that never exits.
    ///
    /// On expiry the child is terminated, then killed. Nothing is left running.
    public static func runBounded(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        maximumOutputBytes: Int = 64 * 1024
    ) -> ProcessOutcome {
        // Before anything else. This is the whole point of a deadline.
        let deadline = DispatchTime.now() + .milliseconds(Int(max(0.05, timeout) * 1000))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        var truncated = false

        // Exit and end-of-output are two different events, and they do not arrive in a fixed order.
        // A short-lived `git` can exit before its last bytes are delivered, so tearing the pipes
        // down on termination alone loses the branch name and the reading looks detached. Both
        // pipes are therefore drained to EOF as well — inside the same deadline, never after it.
        let drained = DispatchSemaphore(value: 0)
        let eofLock = NSLock()
        var eofCount = 0
        func noteEOF() {
            eofLock.lock()
            eofCount += 1
            let done = eofCount == 2
            eofLock.unlock()
            if done { drained.signal() }
        }

        func drain(_ pipe: Pipe, into keep: @escaping (Data) -> Void) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    noteEOF()
                    return
                }
                lock.lock()
                keep(chunk)
                lock.unlock()
            }
        }
        drain(out) { chunk in
            if outData.count < maximumOutputBytes {
                outData.append(chunk.prefix(maximumOutputBytes - outData.count))
                if outData.count >= maximumOutputBytes { truncated = true }
            } else {
                truncated = true      // read and discarded: the child must never block on a full pipe
            }
        }
        drain(err) { chunk in
            if errData.count < maximumOutputBytes {
                errData.append(chunk.prefix(maximumOutputBytes - errData.count))
            } else {
                truncated = true
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }


        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return ProcessOutcome(status: -1, stdout: Data(), stderr: Data(),
                                  timedOut: false, launchFailed: true, outputTruncated: false)
        }

        var timedOut = false
        if finished.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + .milliseconds(250))
            }
        }

        // The child has exited (or been killed). Give the pipes the rest of the budget to deliver
        // what is already written before tearing them down. Still bounded: this waits on EOF with a
        // deadline, never on a blocking read-to-end.
        if !timedOut {
            _ = drained.wait(timeout: deadline)
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()

        lock.lock()
        let capturedOut = outData
        let capturedErr = errData
        let wasTruncated = truncated
        lock.unlock()

        return ProcessOutcome(
            status: timedOut ? -1 : process.terminationStatus,
            stdout: capturedOut, stderr: capturedErr,
            timedOut: timedOut, launchFailed: false, outputTruncated: wasTruncated
        )
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
