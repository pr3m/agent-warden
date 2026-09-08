import Foundation

/// Runs one terminal-scripting request and returns what it said.
///
/// A seam, so the *scheduling* rules below can be exercised deterministically without AppleScript,
/// a window server, or any real terminal.
public protocol ScriptExecuting: Sendable {
    func execute(_ source: String) -> Result<String, GhosttyFailure>
}

/// Process-wide serialisation and deadline enforcement for terminal scripting.
///
/// **Why this is process-wide and not per-object.** Each activation builds its own adapter, and the
/// pairing window owns another. A gate that lived on the instance would let a second adapter queue
/// a request behind a first one that is still blocked: the second caller gives up at its deadline,
/// reports a timeout, and then — minutes later, when the first script finally returns — the queued
/// script runs anyway. For a `focus` that means a terminal jumping to a tab long after the click
/// that asked for it, with nothing on screen to explain why. So:
///
/// - **one gate for the whole process.** While any script is outstanding, every other request is
///   refused *immediately* (`.busy`) instead of being queued. Repeated clicks cannot stack up
///   navigation;
/// - **expiry is checked again immediately before execution.** A request that was accepted but has
///   passed its deadline while waiting to start is abandoned unsent;
/// - **a timed-out request ends its chain.** Nothing retries, and no verification step runs against
///   an answer that cannot be attributed to it.
///
/// **What this cannot do, stated plainly.** An Apple event already delivered to the terminal cannot
/// be recalled. If `focus` was sent and the reply is late, the tab may still change after we have
/// given up waiting. What is guaranteed is narrower and worth having: *no unsent request executes
/// after its deadline*, and no request is ever queued behind a blocked one.
public final class BoundedScriptRunner: @unchecked Sendable {
    /// One queue and one flag for the whole process. `static` on purpose — see above.
    private static let queue = DispatchQueue(label: "ai.wundamental.agent-warden.terminal-script")
    private static let gate = NSLock()
    private static var outstanding = false

    private let executor: ScriptExecuting

    public init(executor: ScriptExecuting) {
        self.executor = executor
    }

    /// True while any runner in this process has a script out. Used by checks, not by policy.
    public static var isBusy: Bool {
        gate.lock(); defer { gate.unlock() }
        return outstanding
    }

    /// Runs `source`, or refuses. Never queues behind a blocked script.
    public func run(_ source: String, timeout: TimeInterval) -> Result<String, GhosttyFailure> {
        BoundedScriptRunner.gate.lock()
        if BoundedScriptRunner.outstanding {
            BoundedScriptRunner.gate.unlock()
            return .failure(.busy)
        }
        BoundedScriptRunner.outstanding = true
        BoundedScriptRunner.gate.unlock()

        let budget = max(0.5, timeout)
        let deadline = DispatchTime.now() + .milliseconds(Int(budget * 1000))
        let resultLock = NSLock()
        var result: Result<String, GhosttyFailure> = .failure(.timedOut)
        let done = DispatchSemaphore(value: 0)
        let executor = self.executor

        // Nothing here captures `self`. The gate has to be released even if this runner is gone by
        // the time the script comes back, and a `weak self` that had become nil would strand it.
        BoundedScriptRunner.queue.async {
            defer {
                BoundedScriptRunner.gate.lock()
                BoundedScriptRunner.outstanding = false
                BoundedScriptRunner.gate.unlock()
                done.signal()
            }
            // The last check before anything leaves this process. If the caller's deadline has
            // already passed, the request is dropped unsent rather than delivered late.
            guard DispatchTime.now() < deadline else {
                resultLock.lock(); result = .failure(.timedOut); resultLock.unlock()
                return
            }
            let outcome = executor.execute(source)
            resultLock.lock(); result = outcome; resultLock.unlock()
        }

        if done.wait(timeout: deadline) == .timedOut { return .failure(.timedOut) }
        resultLock.lock(); defer { resultLock.unlock() }
        return result
    }
}

/// Sends a terminal script from the thread that owns the main run loop.
///
/// **The defect this exists for.** `NSAppleScript` does not simply block waiting for its reply: it
/// waits by *pumping the main event loop* — `UASRemoteSend` → `AEDefaultActiveProc` →
/// `WaitNextEvent` → `CFRunLoopRun`. In a process whose main thread is itself running that loop —
/// `aa-bridge serve`, and the app — a send issued from a background thread leaves two threads
/// draining the same run loop and the same Mach ports. The main thread takes the Apple event reply,
/// has no Apple event handler to give it to, and drops it; the sending thread then waits for an
/// answer that has already been thrown away. Nothing errors and nothing times out, because from
/// AppleScript's point of view nothing failed — the send just never finishes. That is why a visible
/// launch stalled while background start and status answered in milliseconds, and why the same
/// script ran in 0.3s from a standalone probe: a probe has no main run loop to lose the reply to.
///
/// Sending from the main thread makes the wait and the reply the same loop, which is the whole fix.
///
/// **Where there is no main run loop** — a one-shot command, a test host — nothing drains
/// `DispatchQueue.main`, so hopping onto it would *be* the hang this exists to prevent. There the
/// script runs on the calling thread, which is what already worked. The run loop is asked rather
/// than assumed: `CFRunLoopCopyCurrentMode` answers nil for a run loop that is not running, and
/// that is exactly the distinction that matters.
public struct MainRunLoopScriptExecutor: ScriptExecuting {
    private let wrapped: ScriptExecuting
    private let mainRunLoopIsRunning: @Sendable () -> Bool
    private let handoff: TimeInterval

    /// - Parameter handoff: how long to wait for the main thread to take the work. Bounded on
    ///   purpose: a main thread that has stopped servicing its queue must surface as a timeout, not
    ///   as a host that never answers again.
    public init(_ wrapped: ScriptExecuting,
                mainRunLoopIsRunning: @escaping @Sendable () -> Bool = MainRunLoopScriptExecutor.mainRunLoopIsLive,
                handoff: TimeInterval = 30) {
        self.wrapped = wrapped
        self.mainRunLoopIsRunning = mainRunLoopIsRunning
        self.handoff = handoff
    }

    /// True only while the main run loop is actually running.
    @Sendable
    public static func mainRunLoopIsLive() -> Bool {
        CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) != nil
    }

    public func execute(_ source: String) -> Result<String, GhosttyFailure> {
        let wrapped = self.wrapped
        return MainRunLoopScriptExecutor.onMainRunLoop(
            handoff: handoff, mainRunLoopIsRunning: mainRunLoopIsRunning
        ) { wrapped.execute(source) } ?? .failure(.timedOut)
    }

    /// Runs `body` on the thread an Apple event reply can actually reach, and answers `nil` only if
    /// the main thread never took the work within `handoff`.
    ///
    /// The one implementation of this rule. Anything in this process that sends an Apple event goes
    /// through here, because the failure it prevents is a silent, permanent stall rather than an
    /// error anybody would see.
    public static func onMainRunLoop<T: Sendable>(
        handoff: TimeInterval = 30,
        mainRunLoopIsRunning: @Sendable () -> Bool = MainRunLoopScriptExecutor.mainRunLoopIsLive,
        _ body: @escaping @Sendable () -> T
    ) -> T? {
        // Already the right thread. Posting to the main queue from the main thread and then waiting
        // for it would deadlock, so this case is answered before anything is scheduled.
        if Thread.isMainThread { return body() }
        // No main run loop in this process: the main queue is never drained, so the calling thread
        // is the only thread that can finish this.
        guard mainRunLoopIsRunning() else { return body() }

        let lock = NSLock()
        var outcome: T?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let answer = body()
            lock.lock(); outcome = answer; lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + handoff) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return outcome
    }
}

/// Opt-in tracing for the terminal-scripting path, off unless `AGENT_WARDEN_TRACE` is set.
///
/// Bounded on purpose: one line per step, each with the elapsed time and a bounded excerpt of what
/// was asked. The failure this exists for was a *silent* stall — no error, no timeout, nothing in
/// any log — and the only way to see it was a stack sample. A step that never prints its "after"
/// line names the call that never returned.
public enum ScriptTrace {
    public static let enabled = ProcessInfo.processInfo.environment["AGENT_WARDEN_TRACE"] != nil

    private static let lock = NSLock()

    public static func note(_ step: String, _ detail: @autoclosure () -> String = "") {
        guard enabled else { return }
        let text = detail()
        let excerpt = text.count > 120 ? String(text.prefix(120)) + "…" : text
        let line = "[warden.trace] \(stamp()) \(step)\(excerpt.isEmpty ? "" : "  \(excerpt)")\n"
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Times `body`, and says so on both sides so a call that never returns is visible as a missing
    /// line rather than as silence.
    ///
    /// No `@autoclosure` on the detail: a trailing closure would bind to it instead of the body,
    /// which is a compile error at every call site and a trap at none of them.
    public static func step<T>(_ name: String, detail: String = "", _ body: () -> T) -> T {
        guard enabled else { return body() }
        let started = Date()
        note("→ \(name)", detail)
        let outcome = body()
        note("← \(name)", String(format: "%.3fs", Date().timeIntervalSince(started)))
        return outcome
    }

    private static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
