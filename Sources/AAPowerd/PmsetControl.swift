import Foundation
import AgentAttentionCore

/// The only privileged thing this daemon does: write and read the machine-global
/// `SleepDisabled` setting.
///
/// **Why this is two fixed argument vectors and not a command string.** The daemon runs as
/// root and takes its orders off a socket. `acquire` and `release` map to `disablesleep 1`
/// and `disablesleep 0` and to nothing else — the protocol carries no arguments, so there
/// is no value from the wire to interpolate and no shell to interpolate it into. `Process`
/// with an `executableURL` execs directly; it never goes through `/bin/sh`.
///
/// **Why the absolute path.** `pmset` is addressed as `/usr/bin/pmset`. A relative name
/// would be resolved against whatever `PATH` this process inherited, which is a way to
/// make a root daemon exec somebody else's binary.
///
/// **Why every write is read back.** `pmset -a disablesleep` is undocumented and
/// unsupported: it can exit 0 without changing anything. An unverified write is reported as
/// a failure, never as a success, because the alternative is telling the user their Mac
/// will stay awake with the lid shut when it will not.
///
/// **Why every invocation is bounded.** `pmset` is not a self-contained computation: it
/// talks to `powerd` over IPC, and a wedged `powerd` leaves it hanging with no error and no
/// exit. Every call here runs inside `PowerDaemon`'s serial state queue, and that queue also
/// carries the expiry timer — so one unbounded `waitUntilExit` would stop the expiry timer
/// firing, stop `connectionClosed` releasing anything, and leave `SleepDisabled` set with
/// nothing left able to clear it, on a machine `launchd` will not restart because it is hung
/// rather than dead. `BoundedProcess.run` is therefore the only way a child is started here:
/// it kills at the deadline, drains both pipes concurrently so nothing blocks on a full one,
/// and leaves no process behind.
enum PmsetControl {
    /// Fixed, absolute, and never assembled from anything the socket supplied.
    static let executable = "/usr/bin/pmset"

    /// How long one `pmset` invocation may take before it is killed and reported as a failure.
    ///
    /// **Derived from what the caller can tolerate, not chosen by feel.** The app's
    /// `PowerLeaseClient.exchangeDeadline` is 5s for one request and reply. The most expensive
    /// request is `acquire`, and it costs *three* invocations of `pmset` on this side —
    /// `read()` to see whether the setting is already taken, then `write(.on)`, which is itself
    /// `pmset -a disablesleep 1` followed by a verifying `read()`. Three invocations at 1.5s is
    /// 4.5s, which lands inside the app's 5s deadline. That ordering is the whole point: when
    /// `powerd` wedges, the daemon answers `error pmsetFailed` — the honest reason — *before*
    /// the app gives up and reports the transport failure it cannot explain.
    ///
    /// **Bounded below by what a healthy machine actually costs.** Measured on this machine,
    /// `pmset -g` takes 7–11 ms wall clock including the fork and exec (20 runs: min 6.9 ms,
    /// median 8.1 ms, max 10.6 ms). 1.5s is over a hundred times that, so no amount of ordinary
    /// load makes this fire; only a `pmset` that is not coming back does.
    ///
    /// One case runs past the app's deadline and is accepted deliberately: a `write(.on)` that
    /// times out is rolled back by `PowerDaemon.applyGuarded`, which spends up to two more
    /// invocations clearing the block it can no longer account for. That is five in the worst
    /// case, 7.5s, and the app will have given up by then — but roam genuinely did not start,
    /// so the app is not wrong about anything, and the queue is *free* again in bounded time,
    /// which is the property that was missing.
    static let deadline: TimeInterval = 1.5

    /// Set or clear the block, then **verify by reading it back**.
    ///
    /// Returns `nil` on a verified change, or the `PowerError` that describes what went
    /// wrong. `.unverified` means the write reported success and the read-back disagreed —
    /// which is treated exactly like an outright failure, because from the caller's point
    /// of view it is one. A `pmset` that had to be killed at the deadline is `.pmsetFailed`,
    /// alongside one that failed to launch or exited non-zero: all three mean the same thing
    /// here, which is that the privileged operation did not demonstrably happen.
    static func write(_ wanted: SleepDisabled) -> PowerError? {
        // `.unknown` is not a state anything can be written to. Refusing here keeps the
        // caller from ever turning "we could not read it" into "go and set it to that".
        guard wanted == .on || wanted == .off else { return .unverified }
        let value = wanted == .on ? "1" : "0"
        let outcome = BoundedProcess.run(executable: executable,
                                         arguments: ["-a", "disablesleep", value],
                                         timeout: deadline)
        guard !outcome.launchFailed, !outcome.timedOut, outcome.status == 0 else {
            return .pmsetFailed
        }
        return read() == wanted ? nil : .unverified
    }

    /// The current machine-wide setting as `pmset` reports it. Anything we cannot run, cannot
    /// wait out, or cannot parse is `.unknown` and never `.off`.
    static func read() -> SleepDisabled {
        let outcome = BoundedProcess.run(executable: executable, arguments: ["-g"],
                                         timeout: deadline)
        guard !outcome.launchFailed, !outcome.timedOut, outcome.status == 0 else {
            return .unknown
        }
        guard let output = String(data: outcome.stdout, encoding: .utf8) else { return .unknown }
        return SleepDisabled.parse(output)
    }
}
