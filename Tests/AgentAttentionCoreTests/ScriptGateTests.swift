import Foundation
import Testing
@testable import AgentAttentionCore

/// A scripted executor that can be held open on demand.
///
/// Records every source it was actually asked to execute, in order, so a test can assert not just
/// what came back but **what was sent** — which is the whole question here.
private final class ScriptedExecutor: ScriptExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var executed: [String] = []
    private let hold: DispatchSemaphore?
    private let entered = DispatchSemaphore(value: 0)

    init(hold: DispatchSemaphore? = nil) {
        self.hold = hold
    }

    func execute(_ source: String) -> Result<String, GhosttyFailure> {
        lock.lock(); executed.append(source); lock.unlock()
        entered.signal()
        if let hold { hold.wait() }
        return .success("ok")
    }

    var sources: [String] {
        lock.lock(); defer { lock.unlock() }
        return executed
    }

    /// Waits until this executor has actually started a script.
    @discardableResult
    func waitUntilRunning(seconds: TimeInterval = 5) -> Bool {
        entered.wait(timeout: .now() + seconds) == .success
    }
}

/// Two adapters, one process, one gate.
///
/// The defect this suite exists for: the queue was shared but the "a script is outstanding" flag
/// was per-instance. A second adapter could therefore enqueue behind a first one that was blocked,
/// report a timeout to its caller, and then run its script anyway when the first finally returned —
/// a terminal jumping to a tab long after the click that asked for it.
@Suite("Terminal script gate", .serialized)
struct ScriptGateTests {
    private let focusScript = "focus (terminal id \"term-1\")"
    private let readScript = "return id of focused terminal"

    @Test("A second request is refused while another is outstanding, and never sent afterwards")
    func aBlockedScriptNeverLetsALaterOneThrough() throws {
        let release = DispatchSemaphore(value: 0)
        let blocking = ScriptedExecutor(hold: release)
        let second = ScriptedExecutor()

        // Two separate runners, exactly as two adapters would be.
        let first = BoundedScriptRunner(executor: blocking)
        let other = BoundedScriptRunner(executor: second)

        // The first one stalls inside its script and never answers before its deadline.
        let firstOutcome = DispatchQueue.global()
        let firstResult = UnsafeResultBox()
        firstOutcome.async { firstResult.value = first.run(self.readScript, timeout: 0.6) }
        #expect(blocking.waitUntilRunning(), "the first script really is executing")

        // The second asks to focus a tab, while the first is still blocked.
        let secondResult = other.run(focusScript, timeout: 0.5)

        #expect(secondResult.failureValue == .busy,
                "it is refused on the spot, not queued behind the blocked script")
        #expect(second.sources.isEmpty, "and nothing was sent")

        // Let both callers' deadlines pass while the first script is still stuck inside Ghostty.
        Thread.sleep(forTimeInterval: 0.8)
        #expect(firstResult.value?.failureValue == .timedOut,
                "the first caller was told the truth: it timed out")

        // A user clicking again during the stall must not be able to stack up navigation either.
        #expect(other.run(focusScript, timeout: 0.3).failureValue == .busy)
        #expect(second.sources.isEmpty)

        // Now let the first one finish. This is the moment the old code would have run the queued
        // focus — long after its caller had given up.
        release.signal()

        // Give any late work every chance to happen before asserting it did not.
        Thread.sleep(forTimeInterval: 0.4)
        #expect(second.sources.isEmpty,
                "the focus was NEVER sent — not when it was asked for, and not afterwards")
        #expect(blocking.sources == [readScript], "only the first script ever ran")
    }

    @Test("A request whose deadline passes before it can start is dropped unsent")
    func expiredBeforeDispatchIsNotSent() {
        // A runner whose executor would answer instantly, given a deadline that has effectively
        // already gone. The gate's own pre-execution check is the last thing between an expired
        // request and the terminal.
        let executor = ScriptedExecutor()
        let runner = BoundedScriptRunner(executor: executor)

        // Occupy the gate on another thread for longer than the second caller's whole budget, so
        // the second call can only ever be refused — never queued and run late.
        let release = DispatchSemaphore(value: 0)
        let blocking = ScriptedExecutor(hold: release)
        let holder = BoundedScriptRunner(executor: blocking)
        DispatchQueue.global().async { _ = holder.run("hold", timeout: 3) }
        #expect(blocking.waitUntilRunning())

        let result = runner.run(focusScript, timeout: 0.5)
        #expect(result.failureValue == .busy)
        #expect(executor.sources.isEmpty)

        release.signal()
        Thread.sleep(forTimeInterval: 0.3)
        #expect(executor.sources.isEmpty, "still nothing sent after the gate cleared")
    }

    @Test("Requests that do not overlap are served normally")
    func sequentialRequestsWork() {
        let executor = ScriptedExecutor()
        let runner = BoundedScriptRunner(executor: executor)

        #expect((try? runner.run(readScript, timeout: 2).get()) == "ok")
        #expect((try? runner.run(focusScript, timeout: 2).get()) == "ok")
        #expect(executor.sources == [readScript, focusScript])
        #expect(!BoundedScriptRunner.isBusy, "the gate is released after each one")
    }

    @Test("A runner released mid-script still frees the gate")
    func releasingTheRunnerDoesNotStrandTheGate() {
        let release = DispatchSemaphore(value: 0)
        let blocking = ScriptedExecutor(hold: release)
        DispatchQueue.global().async {
            // Deliberately scoped: the runner is gone before the script returns.
            let doomed = BoundedScriptRunner(executor: blocking)
            _ = doomed.run("hold", timeout: 0.5)
        }
        #expect(blocking.waitUntilRunning())
        release.signal()

        // The gate is released by the queue block itself, which captures no `self`.
        var freed = false
        for _ in 0..<50 where !freed {
            Thread.sleep(forTimeInterval: 0.05)
            freed = !BoundedScriptRunner.isBusy
        }
        #expect(freed, "a later request would otherwise be refused for ever")

        let executor = ScriptedExecutor()
        #expect((try? BoundedScriptRunner(executor: executor).run("after", timeout: 2).get()) == "ok")
    }
}

/// A one-slot box for a value produced on another thread.
private final class UnsafeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var stored: Result<String, GhosttyFailure>?

    var value: Result<String, GhosttyFailure>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set {
            lock.lock(); stored = newValue; lock.unlock()
            ready.signal()
        }
    }

    func waitForValue(seconds: TimeInterval = 5) -> Result<String, GhosttyFailure>? {
        _ = ready.wait(timeout: .now() + seconds)
        return value
    }
}

private extension Result where Failure == GhosttyFailure {
    var failureValue: GhosttyFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
