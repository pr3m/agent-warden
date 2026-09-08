import Foundation
import Testing
@testable import AgentAttentionCore

/// Stands in for `NSAppleScript` **in the bridge-host context**.
///
/// The real one waits for its Apple event reply by pumping the main event loop, and that reply is
/// delivered to the main thread. Sent from a background thread in a process whose main thread is
/// itself running that loop, the reply is taken by the main thread and dropped, and the send never
/// returns. This models exactly that: an answer for a main-thread sender, and for anyone else the
/// wait that never ends — bounded here, so a failing test reports in a second rather than hanging a
/// suite. `stall` is the stand-in for "for ever".
private final class MainThreadOnlyReply: ScriptExecuting, @unchecked Sendable {
    private let stall: TimeInterval
    private let lock = NSLock()
    private var senders: [Bool] = []

    init(stall: TimeInterval = 1.0) { self.stall = stall }

    func execute(_ source: String) -> Result<String, GhosttyFailure> {
        let onMain = Thread.isMainThread
        lock.lock(); senders.append(onMain); lock.unlock()
        guard onMain else {
            Thread.sleep(forTimeInterval: stall)      // the reply that never comes
            return .failure(.timedOut)
        }
        return .success("ok")
    }

    /// Which threads the script was actually sent from, in order.
    var sentFromMain: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return senders
    }
}

/// Answers from wherever it is called, and remembers where that was.
private final class ThreadRecordingExecutor: ScriptExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: Bool?

    func execute(_ source: String) -> Result<String, GhosttyFailure> {
        lock.lock(); onMain = Thread.isMainThread; lock.unlock()
        return .success("ok")
    }

    var ranOnMain: Bool? {
        lock.lock(); defer { lock.unlock() }
        return onMain
    }
}

/// Runs `body` off the main thread and waits a **bounded** time for it.
///
/// Every wait in this suite has a deadline. The failure being reproduced is a hang, and a test for
/// a hang that can itself hang is not a test.
private func offMain<T: Sendable>(within seconds: TimeInterval = 8,
                                  _ body: @escaping @Sendable () -> T) -> T? {
    let box = NSLock()
    var value: T?
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let outcome = body()
        box.lock(); value = outcome; box.unlock()
        done.signal()
    }
    guard done.wait(timeout: .now() + seconds) == .success else { return nil }
    box.lock(); defer { box.unlock() }
    return value
}

@Suite("Terminal scripts and the main run loop", .serialized)
struct ScriptMainThreadTests {

    /// The regression. Before the fix the bridge host sent its Ghostty scripts from
    /// `BoundedScriptRunner`'s background queue while `RunLoop.main.run()` was pumping, and the
    /// visible launch stalled with no error and no timeout — `aa-bridge start --terminal ghostty`
    /// simply never answered, while background start and status answered in milliseconds.
    @Test("A script sent in the bridge-host context is answered, because it is sent from the main thread")
    func aScriptSurvivesTheBridgeHostContext() {
        let ghostty = MainThreadOnlyReply()
        // `mainRunLoopIsRunning: { true }` *is* the bridge-host context: `aa-bridge serve` ends in
        // `RunLoop.main.run()`. It is injected rather than observed so the reproduction does not
        // depend on whether the test host happens to be pumping its own run loop.
        let subject = MainRunLoopScriptExecutor(ghostty, mainRunLoopIsRunning: { true }, handoff: 6)

        let outcome = offMain { subject.execute("return (count of windows) as text") }

        #expect(outcome != nil, "the send must come back at all — the defect was that it never did")
        #expect(try! outcome?.get() == "ok")
        #expect(ghostty.sentFromMain == [true],
                "the script must be sent once, from the main thread, or its reply is lost")
    }

    /// The other half of the same rule. A one-shot command and a test host have no main run loop, so
    /// nothing drains `DispatchQueue.main`; posting there would be the very hang this prevents.
    @Test("Without a main run loop the script runs on the calling thread instead of a queue nothing drains")
    func withoutAMainRunLoopTheScriptRunsInline() {
        let recorder = ThreadRecordingExecutor()
        let subject = MainRunLoopScriptExecutor(recorder, mainRunLoopIsRunning: { false }, handoff: 6)

        let outcome = offMain { subject.execute("return id of front window") }

        #expect(outcome != nil, "a process with no main run loop must still get an answer")
        #expect(try! outcome?.get() == "ok")
        #expect(recorder.ranOnMain == false, "there was no main run loop to hand it to")
    }

    /// Called on the main thread, posting to the main queue and waiting for it would deadlock. The
    /// main thread is already the thread the reply arrives on, so the script runs where it is.
    @Test("A caller that is already the main thread runs the script inline rather than deadlocking")
    func aMainThreadCallerDoesNotDeadlock() {
        let recorder = ThreadRecordingExecutor()
        let subject = MainRunLoopScriptExecutor(recorder, mainRunLoopIsRunning: { true }, handoff: 6)

        let done = DispatchSemaphore(value: 0)
        let box = NSLock()
        var answer: Result<String, GhosttyFailure>?
        DispatchQueue.main.async {
            let outcome = subject.execute("focus (terminal id \"term-1\")")
            box.lock(); answer = outcome; box.unlock()
            done.signal()
        }
        // Bounded: if this ever deadlocks it must be reported, not waited on.
        guard done.wait(timeout: .now() + 8) == .success else {
            Issue.record("a main-thread caller deadlocked posting to its own queue")
            return
        }
        box.lock(); let outcome = answer; box.unlock()
        #expect(try! outcome?.get() == "ok")
        #expect(recorder.ranOnMain == true)
    }

    /// A main thread that has stopped servicing its queue must surface as a timeout rather than as a
    /// host that never answers again. This is the guarantee that replaces the hang.
    @Test("A main thread that never takes the work is a bounded timeout, not a stall")
    func anUnservicedMainQueueTimesOutRatherThanHanging() {
        let recorder = ThreadRecordingExecutor()
        // Claims a main run loop that is not actually draining anything, which is the worst case.
        let subject = MainRunLoopScriptExecutor(recorder, mainRunLoopIsRunning: { true }, handoff: 0.75)

        let started = Date()
        let outcome = offMain(within: 8) { subject.execute("return (count of windows) as text") }
        let elapsed = Date().timeIntervalSince(started)

        #expect(outcome != nil, "it must give up, not hang")
        if case .failure(let failure)? = outcome {
            #expect(failure == .timedOut)
        } else {
            // A test host that *does* pump its main queue will legitimately answer here; that is the
            // fixed behaviour, not a failure. What must never happen is neither answer arriving.
            #expect(recorder.ranOnMain == true, "either it timed out, or the main thread ran it")
        }
        #expect(elapsed < 7, "the wait is bounded by the handoff, not by the caller giving up")
    }

    /// Wiring, not mechanism. The type above is only a fix if the adapter the bridge host actually
    /// builds is the one using it — that was the whole gap between "the script works in a probe" and
    /// "the visible launch stalls".
    @Test("The Ghostty surface adapter sends its scripts through the main run loop")
    func theSurfaceAdapterIsWiredToTheMainRunLoop() {
        #expect(GhosttySurfaceAdapter.productionExecutor() is MainRunLoopScriptExecutor,
                "a raw NSAppleScript send from the host's background queue is the defect itself")
    }
}
