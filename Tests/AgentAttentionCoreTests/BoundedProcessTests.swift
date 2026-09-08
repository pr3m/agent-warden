import Foundation
import Testing
@testable import AgentAttentionCore

/// A timeout that is not enforced is a comment.
///
/// The first version of this read stdout to the end, then stderr, and *then* started measuring a
/// deadline. Against a hung child the first read never returns, so the deadline is never reached;
/// against a chatty child the two sequential reads deadlock as soon as the pipe we are not reading
/// fills up. Both are exercised here with real child processes, not with a stubbed enum.
@Suite("Bounded child processes")
struct BoundedProcessTests {
    private let shell = "/bin/sh"

    private func run(_ script: String, timeout: TimeInterval, cap: Int = 64 * 1024) -> (GitBranchProbe.ProcessOutcome, TimeInterval) {
        let started = Date()
        let outcome = GitBranchProbe.runBounded(
            executable: shell, arguments: ["-c", script], timeout: timeout, maximumOutputBytes: cap)
        return (outcome, Date().timeIntervalSince(started))
    }

    @Test("A child that never exits is killed at the deadline, not waited on forever")
    func hungChildIsKilled() {
        let (outcome, elapsed) = run("sleep 60", timeout: 0.5)

        #expect(outcome.timedOut)
        #expect(!outcome.launchFailed)
        #expect(elapsed < 5, "it returned in \(elapsed)s, so the deadline was real")
    }

    @Test("A child that holds a pipe open and then hangs is still killed")
    func hungChildWithOpenPipesIsKilled() {
        // The shape that made the old code hang forever: something is written, the pipe stays open,
        // and the child never exits. `readToEnd` would still be waiting.
        let (outcome, elapsed) = run("echo starting; sleep 60", timeout: 0.5)

        #expect(outcome.timedOut)
        #expect(elapsed < 5)
    }

    @Test("A child writing hard to BOTH pipes cannot deadlock the reader")
    func bothPipesDrainConcurrently() {
        // Far more than a pipe buffer on either side. Reading one to the end before touching the
        // other blocks the child on the pipe nobody is draining, and neither side ever finishes.
        let script = """
        i=0
        while [ $i -lt 400 ]; do
          printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n'
          printf 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\\n' >&2
          i=$((i+1))
        done
        exit 7
        """
        let (outcome, elapsed) = run(script, timeout: 10)

        #expect(!outcome.timedOut, "it finished, so nothing deadlocked")
        #expect(outcome.status == 7, "and its real exit status came back")
        #expect(!outcome.stdout.isEmpty)
        #expect(!outcome.stderr.isEmpty)
        #expect(elapsed < 10)
    }

    @Test("A child that prints far more than we will hold still finishes")
    func hugeOutputIsBoundedWithoutBlockingTheChild() {
        // The excess has to be read and discarded. Leaving it in the pipe blocks the child forever,
        // and then the bound would have caused the hang it was meant to prevent.
        let script = "i=0; while [ $i -lt 2000 ]; do printf '%s\\n' " +
            "'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'; i=$((i+1)); done"
        let (outcome, elapsed) = run(script, timeout: 10, cap: 4096)

        #expect(!outcome.timedOut, "the child was never blocked on a full pipe")
        #expect(outcome.status == 0)
        #expect(outcome.stdout.count <= 4096, "and we held only what we said we would")
        #expect(outcome.outputTruncated)
        #expect(elapsed < 10)
    }

    @Test("A child that prints and exits immediately still hands back everything it printed",
          arguments: 1...12)
    func fastChildOutputIsNotLostToTermination(_ attempt: Int) {
        // Termination fires as soon as the child exits, which can be *before* the reader has been
        // handed the last chunk of the pipe. Tearing the handlers down at that moment loses the
        // branch name that was already written — intermittently, which is the worst kind. Repeated,
        // because a race that only shows one time in ten is still a race.
        let (outcome, _) = run("printf 'cs/red658-plan-vs-ledger\\n'; printf 'warn\\n' >&2; exit 0",
                               timeout: 5)

        #expect(!outcome.timedOut)
        #expect(outcome.status == 0)
        #expect(String(decoding: outcome.stdout, as: UTF8.self).contains("cs/red658-plan-vs-ledger"),
                "attempt \(attempt) came back empty, so the drain lost a completed write")
        #expect(String(decoding: outcome.stderr, as: UTF8.self).contains("warn"))
    }

    @Test("An ordinary quick child is not slowed down by any of this")
    func quickChildIsQuick() {
        let (outcome, elapsed) = run("printf 'cs/red645-own-capital\\n'", timeout: 5)
        #expect(!outcome.timedOut)
        #expect(outcome.status == 0)
        #expect(String(decoding: outcome.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == "cs/red645-own-capital")
        #expect(elapsed < 3)
    }

    @Test("A non-zero exit is reported with its stderr")
    func failureCarriesStderr() {
        let (outcome, _) = run("printf 'fatal: not a git repository\\n' >&2; exit 128", timeout: 5)
        #expect(outcome.status == 128)
        #expect(String(decoding: outcome.stderr, as: UTF8.self).contains("not a git repository"))
        #expect(GitBranchProbe.classify(status: outcome.status, stdout: outcome.stdout, stderr: outcome.stderr)
                == .notARepository)
    }

    @Test("An executable that is not there is a launch failure, not a timeout")
    func missingExecutable() {
        let outcome = GitBranchProbe.runBounded(
            executable: "/nonexistent-\(UUID().uuidString)", arguments: [], timeout: 1)
        #expect(outcome.launchFailed)
        #expect(!outcome.timedOut)
    }

    @Test("Nothing is left running after a timeout")
    func nothingSurvivesTheTimeout() throws {
        // A child that writes its own pid, then hangs. After the deadline it must be gone.
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-warden-pid-\(UUID().uuidString)")
        let outcome = GitBranchProbe.runBounded(
            executable: shell,
            arguments: ["-c", "echo $$ > \(marker.path); sleep 60"],
            timeout: 0.5
        )
        #expect(outcome.timedOut)

        // Give the kill a moment to land, then check the pid really is gone.
        Thread.sleep(forTimeInterval: 0.4)
        let text = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: marker)
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(pid > 0, "the child did start")
        #expect(kill(pid, 0) != 0 || errno == ESRCH, "and it is not still running")
    }

    @Test("The probe reports a timeout rather than a branch when git does not answer")
    func probeSurfacesTheTimeout() {
        // Through the public entry point, with the real classification path.
        let outcome = GitBranchProbe.runBounded(executable: shell, arguments: ["-c", "sleep 60"], timeout: 0.4)
        #expect(outcome.timedOut)
        let fact = BranchFact.git(.timedOut, path: "/w/alpha", at: Date())
        #expect(fact.state == "timedOut")
        #expect(fact.branch == nil, "and no name is invented in place of an answer")
    }
}
