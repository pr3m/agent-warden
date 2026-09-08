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
