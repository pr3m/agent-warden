import Foundation

/// Running a child process with a deadline that is actually enforced.
///
/// Lifted out of `GitBranchProbe`, where it was first written, once a second caller needed it:
/// `PmsetControl` in the root power daemon, whose two `pmset` invocations talk to `powerd` over
/// IPC and hang outright when `powerd` is wedged — the exact condition a lid-closed roam session
/// runs into under thermal and power stress. Two callers with one shared implementation is also
/// one place to get the three hard parts right, rather than two places to get them wrong.
public enum BoundedProcess {
    /// What a bounded run produced.
    public struct Outcome: Sendable, Equatable {
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
    /// On expiry the child is terminated, then killed. Nothing is left running: `Process` keeps its
    /// own exit monitor on the pid and reaps it, so a killed child leaves no zombie, and both read
    /// handles are unhooked and closed on the way out, so no reader is left blocked on a pipe whose
    /// writer has gone.
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        maximumOutputBytes: Int = 64 * 1024
    ) -> Outcome {
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
        // A short-lived child can exit before its last bytes are delivered, so tearing the pipes
        // down on termination alone loses output that was already written and the answer looks
        // empty. Both pipes are therefore drained to EOF as well — inside the same deadline, never
        // after it.
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
            return Outcome(status: -1, stdout: Data(), stderr: Data(),
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

        return Outcome(
            status: timedOut ? -1 : process.terminationStatus,
            stdout: capturedOut, stderr: capturedErr,
            timedOut: timedOut, launchFailed: false, outputTruncated: wasTruncated
        )
    }
}
