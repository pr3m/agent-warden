import Foundation

/// One running bridge host, as the supervisor sees it.
public protocol SupervisedProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    /// SIGTERM to this process and nothing else.
    func terminate()
    /// SIGKILL to this process and nothing else. Only ever after a bounded wait for `terminate`.
    func kill()
}

public protocol SupervisedLaunching: Sendable {
    func launch(onExit: @escaping @Sendable (Int32) -> Void) throws -> SupervisedProcess
}

/// Keeps the app's bridge host running for exactly as long as the app is.
///
/// A host started by hand lived only as long as whatever started it, and when that went the host
/// went too — twice, taking the session it had just launched with it. So the app owns it now:
///
/// - **Restart after a crash**, with a backoff that doubles to a minute and resets once a host has
///   stayed up for a minute. A host that dies at once is not restarted in a tight loop.
/// - **Health**, asked of the host itself: a `status` request over its socket. Three failures in a
///   row and the host is stopped, which restarts it through the same path as a crash.
/// - **Another host is not a crash.** A host that exits 75 found a live host already on the socket
///   — one somebody started by hand. It is left alone and asked about again every half minute, so
///   two hosts never fight over one socket and neither ever deletes the other's.
/// - **Shutdown is confirmed.** `stop` asks, waits for the exit to be seen, and only then insists.
public final class BridgeSupervisor: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case running(pid: Int32)
        case backingOff(attempt: Int)
        /// Another host holds the socket. Not ours to replace.
        case externalHost
        case stopped
    }

    public struct Policy: Sendable {
        public var initialBackoff: TimeInterval = 1
        public var maximumBackoff: TimeInterval = 60
        /// Up this long, and the next crash starts the backoff from the beginning again.
        public var healthyUptime: TimeInterval = 60
        public var healthInterval: TimeInterval = 30
        public var unhealthyAfter = 3
        public var externalRecheck: TimeInterval = 30
        public var stopGrace: TimeInterval = 6
        /// How long `stop()` waits for a launch that is already in flight to record its child.
        /// Short, because it covers one `posix_spawn` returning, not a process doing any work.
        public var launchSettleGrace: TimeInterval = 2
        public init() {}
    }

    /// The exit status `aa-bridge serve` uses for "a host is already listening here".
    public static let hostAlreadyRunning: Int32 = 75

    private let launcher: SupervisedLaunching
    private let healthCheck: @Sendable () -> Bool
    private let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let now: @Sendable () -> Date
    private let policy: Policy
    private let lock = NSLock()
    private var process: SupervisedProcess?
    private var startedAt: Date?
    private var attempt = 0
    private var failedChecks = 0
    private var stopping = false
    /// True from the moment a launch passes its guard until the spawn has returned and been
    /// recorded — the window in which a child exists that `process` cannot name.
    private var launching = false
    /// Bumped on every launch, so a timer or an exit from an earlier host acts on nothing.
    private var generation = 0
    private var lastExited = -1
    private var current: State = .idle
    public var log: (@Sendable (String) -> Void)?

    public init(launcher: SupervisedLaunching,
                healthCheck: @escaping @Sendable () -> Bool,
                policy: Policy = Policy(),
                now: @escaping @Sendable () -> Date = { Date() },
                schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
                }) {
        self.launcher = launcher
        self.healthCheck = healthCheck
        self.policy = policy
        self.now = now
        self.schedule = schedule
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func start() {
        lock.lock()
        stopping = false
        let running = process?.isRunning == true
        lock.unlock()
        if !running { launch() }
    }

    private func launch() {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        generation += 1
        let mine = generation
        // Claimed before the lock is dropped, because between here and the spawn returning there is
        // a child that exists and that `process` does not yet name. `stop()` waits on this flag; a
        // bare `process == nil` check would call that window "nothing is running".
        launching = true
        lock.unlock()
        do {
            let child = try launcher.launch { [weak self] status in self?.exited(status, generation: mine) }
            lock.lock()
            launching = false
            // An exit can land before `launch` returns. It has then been handled already, and a
            // dead child must not be installed over it.
            let alreadyExited = lastExited == mine
            let stopRequested = stopping
            if !alreadyExited {
                process = child
                startedAt = now()
                failedChecks = 0
                if !stopRequested { current = .running(pid: child.pid) }
            }
            lock.unlock()
            // A stop that arrived while this was launching still wins: otherwise the host it could
            // not see yet would outlive the app.
            if stopRequested, !alreadyExited { child.terminate(); return }
            guard !alreadyExited else { return }
            log?("bridge host started, pid \(child.pid)")
            scheduleHealth(mine)
        } catch {
            lock.lock(); launching = false; lock.unlock()
            log?("bridge host could not be started: \(error.localizedDescription)")
            retry(after: nextBackoff(), generation: mine)
        }
    }

    private func exited(_ status: Int32, generation exitedGeneration: Int) {
        lock.lock()
        guard exitedGeneration == generation else { lock.unlock(); return }
        lastExited = exitedGeneration
        process = nil
        if stopping {
            current = .stopped
            lock.unlock()
            log?("bridge host stopped (status \(status))")
            return
        }
        if status == BridgeSupervisor.hostAlreadyRunning {
            current = .externalHost
            lock.unlock()
            log?("another bridge host is already listening; leaving it alone")
            retry(after: policy.externalRecheck, generation: exitedGeneration)
            return
        }
        // A host that stayed up long enough was healthy; this crash starts the count again.
        if let startedAt, now().timeIntervalSince(startedAt) >= policy.healthyUptime { attempt = 0 }
        lock.unlock()
        log?("bridge host exited with status \(status); restarting")
        retry(after: nextBackoff(), generation: exitedGeneration)
    }

    private func nextBackoff() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let delay = min(policy.maximumBackoff, policy.initialBackoff * pow(2, Double(attempt)))
        attempt += 1
        current = .backingOff(attempt: attempt)
        return delay
    }

    private func retry(after delay: TimeInterval, generation expected: Int) {
        schedule(delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = self.generation != expected || self.stopping
            self.lock.unlock()
            if !stale { self.launch() }
        }
    }

    private func scheduleHealth(_ expected: Int) {
        schedule(policy.healthInterval) { [weak self] in self?.checkHealth(expected) }
    }

    /// Public so a caller — a test, or the app on wake — can ask now rather than wait.
    public func checkHealth() {
        lock.lock(); let mine = generation; lock.unlock()
        checkHealth(mine, reschedule: false)
    }

    private func checkHealth(_ expected: Int, reschedule: Bool = true) {
        lock.lock()
        guard expected == generation, !stopping, let child = process else { lock.unlock(); return }
        lock.unlock()
        let healthy = healthCheck()
        lock.lock()
        guard expected == generation, !stopping else { lock.unlock(); return }
        failedChecks = healthy ? 0 : failedChecks + 1
        let giveUp = failedChecks >= policy.unhealthyAfter
        lock.unlock()
        if giveUp {
            log?("bridge host did not answer \(policy.unhealthyAfter) health checks; restarting it")
            child.terminate()                    // its exit restarts it, through the crash path
        }
        if reschedule { scheduleHealth(expected) }
    }

    /// Ask the host to go, wait — bounded — for its exit to be seen, and only then insist. Returns
    /// whether it was seen to go.
    ///
    /// **The wait blocks the caller's thread on purpose, and a review that asks for it to be moved
    /// off the main thread is asking for the wrong thing.** The only caller is
    /// `applicationWillTerminate`, and that method returning *is* the process exiting: a wait moved
    /// to a background queue would be cut off mid-way, leaving the host killed rather than asked,
    /// and its claude children orphaned. `Scripts/smoke-test.sh` asserts the opposite — that no
    /// client the host started outlives it.
    ///
    /// The grace is six seconds and costs nothing in the normal case, because the loop ends the
    /// moment the child is gone and a healthy host goes in milliseconds. It is spent only when the
    /// host is already wedged, which is exactly when spending it is right: the alternative is to
    /// force-kill sooner and orphan whatever it was supervising.
    @discardableResult
    public func stop() -> Bool {
        lock.lock()
        stopping = true
        // A launch already past its guard has spawned a child that `process` does not name yet.
        // Waiting for it to settle is the difference between terminating that child and telling the
        // caller "nothing was running" while it is still being born.
        let settleBy = Date().addingTimeInterval(policy.launchSettleGrace)
        while launching && Date() < settleBy {
            lock.unlock()
            usleep(20_000)
            lock.lock()
        }
        let stillLaunching = launching
        let child = process
        if child == nil && !stillLaunching { current = .stopped }
        lock.unlock()
        if stillLaunching {
            log?("bridge host was still launching after \(policy.launchSettleGrace)s; it may outlive the app")
            return false
        }
        guard let child else { return true }
        child.terminate()
        let deadline = Date().addingTimeInterval(policy.stopGrace)
        while child.isRunning && Date() < deadline { usleep(50_000) }
        if child.isRunning {
            log?("bridge host did not stop within \(Int(policy.stopGrace))s; forcing pid \(child.pid)")
            child.kill()
            return false
        }
        lock.lock(); current = .stopped; lock.unlock()
        return true
    }
}

/// `aa-bridge serve`, as a child of the app.
public struct BridgeHostProcessLauncher: SupervisedLaunching {
    public let executable: String
    public let arguments: [String]
    /// Where the host's own diagnostics go. Trimmed at each launch so it cannot grow for ever.
    public let logFile: URL

    public init(executable: String, arguments: [String], logFile: URL) {
        self.executable = executable
        self.arguments = arguments
        self.logFile = logFile
    }

    public func launch(onExit: @escaping @Sendable (Int32) -> Void) throws -> SupervisedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        if let size = (try? FileManager.default.attributesOfItem(atPath: logFile.path))?[.size] as? NSNumber,
           size.intValue > 256 * 1024 {
            try? FileManager.default.removeItem(at: logFile)
        }
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        let log = try? FileHandle(forWritingTo: logFile)
        log?.seekToEndOfFile()
        process.standardError = log ?? FileHandle.nullDevice
        process.terminationHandler = { finished in
            try? log?.close()                     // this launch's descriptor, closed with it
            onExit(finished.terminationStatus)
        }
        try process.run()
        return Child(process: process)
    }

    final class Child: SupervisedProcess, @unchecked Sendable {
        let process: Process
        init(process: Process) { self.process = process }
        var pid: Int32 { process.processIdentifier }
        var isRunning: Bool { process.isRunning }
        func terminate() { if process.isRunning { process.terminate() } }
        func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
    }
}
