import Foundation
import os
import AgentAttentionCore

/// Unified logging, never a log file.
///
/// A root daemon that opens a path for appending is a symlink and an ownership hazard: any
/// path it could be pointed at, it would write to as root. `os.Logger` has no path to
/// point anywhere — the messages go to the system log, where `log stream --predicate
/// 'subsystem == "dev.agentwarden.powerd"'` reads them without this process ever holding a
/// writable file descriptor.
///
/// It is a free-standing type rather than a method so that `main.swift` can report a
/// refusal to start *before* there is a daemon to report it.
enum PowerdLog {
    private static let logger = Logger(subsystem: "dev.agentwarden.powerd", category: "daemon")

    /// Messages are marked public deliberately: every one of them is a literal written
    /// here, plus integers this daemon computed. Nothing from a client's socket is logged,
    /// so there is nothing to redact and a `<private>` placeholder would only make the log
    /// useless for the operator who needs it.
    static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}

/// Serves the lease over a launchd-provided socket.
///
/// **Why launchd owns the socket.** The endpoint is declared in the LaunchDaemon plist and
/// obtained with `launch_activate_socket`, so launchd — not this process — creates it and
/// sets its owner and mode before anything can connect. That removes every
/// bind/unlink/stale-inode race in one move, and it is why none of `BridgeSocketServer`'s
/// setup is reused here: its `verifyPrivateParent` requires a 0700 directory owned by the
/// running process, which a shared root directory can never be.
///
/// **Why one serial queue around everything.** `PowerLease` is deliberately pure and has no
/// locking of its own, so its `holder`/`deadline` pair races the moment two threads touch
/// it. Every call into the lease — `acquire`, `renew`, `release`, `disconnected`,
/// `expireIfDue` — goes through `queue`, and the expiry timer is scheduled *on that same
/// queue*. Two consequences worth stating out loud: a `pmset` call holds the queue for its
/// duration (correct — the lease must not advance while the machine's state is in flight),
/// and nothing may call back into `queue.sync` from inside it.
///
/// **And therefore every `pmset` call must be bounded.** Scheduling the expiry timer on the
/// state queue is what makes it independent of any one connection's read loop — but it also
/// means the timer inherits whatever that queue is blocked on. A `pmset` that never returns
/// would stop the timer firing, block `connectionClosed` so a disconnect released nothing,
/// and pile every further request into `queue.sync` behind it, leaving `SleepDisabled` set
/// with nothing left able to clear it and a hung daemon `launchd` will not restart. That is
/// the same failure the timer's own comment reasons about below, arriving from the other
/// side, and the answer is `PmsetControl.deadline`: every invocation is killed at 1.5s and
/// reported as `.pmsetFailed`, so the queue is always free again in bounded time.
///
/// `@unchecked Sendable` because that queue, not the compiler, is what makes this safe:
/// connections are served on their own threads and all of them reach this object.
final class PowerDaemon: @unchecked Sendable {
    private var lease = PowerLease()
    private let queue = DispatchQueue(label: "dev.agentwarden.powerd.state")
    private var nextConnectionID = 1
    private var expiryTimer: DispatchSourceTimer?

    /// The single uid permitted to talk to this daemon, read by `main.swift` from a
    /// root-owned file.
    let allowedUID: uid_t

    init(allowedUID: uid_t) {
        self.allowedUID = allowedUID
    }

    /// Startup reconciliation. Runs before any client can be served.
    ///
    /// The daemon holds no lease at this point by definition, so it clears the block
    /// **only** when its own marker says it was the one that set it. No marker means
    /// somebody else owns the setting, and a root daemon that clears settings it does not
    /// own is a bug with teeth.
    func reconcile() {
        switch PmsetControl.read() {
        case .off:
            // The block is not set, so any marker left behind is stale by definition.
            HeldMarker.clear()
        case .unknown:
            // Never turn "cannot read it" into "it is not set". Dropping the marker here
            // would disown a block we may well have set, and the next startup — the one
            // that can read `pmset` again — would then find `SleepDisabled 1` with no
            // marker and correctly refuse to touch it. The machine would be stranded awake
            // by our own tidying.
            log("could not read SleepDisabled at startup — leaving any marker in place")
        case .on:
            guard HeldMarker.exists else {
                log("SleepDisabled is set but no marker of ours — leaving it alone")
                return
            }
            HeldMarker.clear()
            if let error = PmsetControl.write(.off) {
                log("startup revert failed: \(error.rawValue)")
            } else {
                log("reverted a block left by a previous run")
            }
        }
    }

    /// The expiry timer, on its own dispatch source and on the state queue.
    ///
    /// Deliberately *not* driven by the connection read loop. A timer serviced by that loop
    /// stops firing exactly when the loop hangs — and a hung holder is precisely the case
    /// the expiry exists to catch, the one a closed socket cannot. Five seconds against a
    /// 45-second expiry gives the deadline enough resolution without waking the machine
    /// pointlessly.
    func startExpiryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Already on `queue`: the source was created with it, so this must not `sync`.
            self.apply(self.lease.expireIfDue(now: Date()))
        }
        timer.resume()
        expiryTimer = timer
    }

    /// Answer one request. `connection` identifies the peer, which is how the lease tells
    /// its holder apart from a passing `status` caller on another socket.
    func handle(_ request: PowerRequest, connection: Int) -> PowerReply {
        return queue.sync { () -> PowerReply in
            switch request {
            case .hello(let version):
                return version == PowerProtocolVersion.current
                    ? .okVersion(PowerProtocolVersion.current)
                    : .error(.version)
            case .acquire:
                let decision = lease.acquire(connection: connection,
                                             observed: PmsetControl.read(), now: Date())
                return applyGuarded(decision, connection: connection)
            case .renew:
                return lease.renew(connection: connection, now: Date()).reply
            case .release:
                return applyGuarded(lease.release(connection: connection),
                                    connection: connection)
            case .status:
                return lease.status(now: Date(), observed: PmsetControl.read()).reply
            }
        }
    }

    /// Apply a decision's effect and report what actually happened.
    ///
    /// A failed `pmset` undoes the lease bookkeeping that was done in anticipation of it,
    /// so the daemon's idea of the world never runs ahead of the machine's: a client that
    /// is told `error` must not be left holding a lease, and a block that could not be
    /// verified must not be left standing with nothing tracking it.
    ///
    /// Caller must already be on `queue`.
    private func applyGuarded(_ decision: PowerLease.Decision, connection: Int) -> PowerReply {
        switch decision.effect {
        case .none:
            return decision.reply
        case .setBlock:
            if let error = PmsetControl.write(.on) {
                // The lease granted only because the block was observed *not* already set
                // by somebody else, so whatever half-state that write left behind is ours
                // to undo. Rolling the lease back yields `.clearBlock`, which is exactly
                // the revert — marker first, then `pmset` — so route it through `apply`
                // rather than reimplementing the ordering here.
                log("could not set the block (\(error.rawValue)) — rolling back")
                apply(lease.release(connection: connection).effect)
                return .error(error)
            }
            HeldMarker.write()
            return decision.reply
        case .clearBlock:
            HeldMarker.clear()
            if let error = PmsetControl.write(.off) { return .error(error) }
            return decision.reply
        }
    }

    /// Apply an effect that nobody is waiting on an answer to — an expiry or a dropped
    /// connection. Caller must already be on `queue`.
    private func apply(_ effect: PowerLease.Effect) {
        switch effect {
        case .none:
            break
        case .setBlock:
            // Unreachable from the timer and disconnect paths, which only ever give up a
            // lease. Handled rather than trapped so that a future lease rule cannot turn a
            // missing case into a silently ignored privileged write.
            if PmsetControl.write(.on) == nil { HeldMarker.write() }
        case .clearBlock:
            HeldMarker.clear()
            if let error = PmsetControl.write(.off) {
                log("revert failed: \(error.rawValue)")
            } else {
                log("lease ended — block cleared")
            }
        }
    }

    /// A client's socket closed. Only the holder's closing changes anything, and the lease
    /// decides that — this just serializes the question.
    func connectionClosed(_ connection: Int) {
        queue.sync { apply(lease.disconnected(connection: connection)) }
    }

    /// This daemon is being stopped. Give the block back before going.
    ///
    /// **Why a daemon needs this at all**, when `reconcile()` already repairs a stranded block:
    /// reconcile runs at *startup*. `launchctl bootout system/dev.agentwarden.powerd` — which is
    /// what an uninstall, an upgrade and an administrator all do — stops this process and does
    /// not start it again, so the next reconcile is at the next boot. Between the two, the Mac
    /// cannot sleep and nothing running knows why. The design lists this among the things the
    /// daemon needs because `KeepAlive` is "a likely recovery path, not a guarantee".
    ///
    /// Everything here is the ordinary release path, not a special one: the same `clearBlock`
    /// effect, applied through the same `apply`, which clears the marker before the setting for
    /// the same reason it always does. The expiry timer is cancelled first so it cannot fire
    /// against a lease that is being given up.
    ///
    /// **Bounded, and that is what makes it usable from a signal handler's queue.** `queue.sync`
    /// waits for whatever the state queue is doing, and since every `pmset` call is now capped at
    /// `PmsetControl.deadline` that wait has a ceiling well inside `launchd`'s grace period
    /// before it escalates to `SIGKILL`. Before that cap this could have blocked forever, and a
    /// shutdown handler that never returns is worse than none.
    func shutdown() {
        queue.sync {
            expiryTimer?.cancel()
            expiryTimer = nil
            apply(lease.relinquish())
        }
    }

    /// Hand out the next connection identity. Serialized like everything else, because the
    /// counter is what the lease uses to recognise its holder and two peers must never
    /// receive the same one.
    func claimConnectionID() -> Int {
        return queue.sync { defer { nextConnectionID += 1 }; return nextConnectionID }
    }

    func log(_ message: String) {
        PowerdLog.write(message)
    }
}
