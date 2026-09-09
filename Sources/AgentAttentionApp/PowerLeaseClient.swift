import Foundation
import AgentAttentionCore

/// `PowerError` is declared in Core as a plain `String`-raw-valued enum, with no `Error`
/// conformance — nothing in Core needs one, because the daemon carries errors as replies on
/// a wire rather than throwing them. `Result<Void, PowerError>`, which is the interface this
/// client is specified to present, requires it, so it is declared here.
///
/// **Deliberately additive and deliberately not a Core edit.** Conformance is all that is
/// missing; there is no behaviour to add. Putting it in Core would be the tidier home, and
/// that is the right place for it if roam ever grows a second consumer — this is the one
/// thing in this file that a later task may want to move up. Left here for now because the
/// alternative is editing a reviewed protocol file to satisfy one call site.
///
/// If Core ever declares `Error` itself, this line stops compiling rather than silently
/// disagreeing — which is the failure mode to want, since two conformances for one type is
/// the thing that produces undefined behaviour at runtime.
extension PowerError: Error {}

/// The app's end of the power lease: one long-lived connection to the root daemon that
/// holds the machine's lid-close sleep block for as long as somebody is roaming.
///
/// **Why not `BridgeSocketClient`.** Three of its assumptions do not hold here, and each on
/// its own rules it out:
///
/// - It is explicitly one-shot — connect, send, read, `close` before returning. The lease
///   *is* the connection: the daemon drops the block when the holder's socket ends, so a
///   client that closed after `acquire` would release the block it had just taken.
/// - It requires the peer's uid to equal its own. Here the peer is root, which is exactly
///   the answer that check would refuse.
/// - It speaks JSON `BridgeRequest`/`BridgeResponse`. This socket speaks the newline-framed
///   verb protocol in `PowerProtocol`.
///
/// The *ideas* are reused — address construction, bounded framing, partial-write handling,
/// a credential check on the peer — and none of the code is.
///
/// **Why the app renews at all**, when the daemon already drops the lease when this
/// connection closes: a closed socket catches an app that exited or crashed, and misses the
/// one that is alive but wedged — deadlocked, stopped, or simply no longer running its own
/// timers — holding the socket open with nobody minding the battery. So the daemon expires
/// the lease `PowerLease.expiry` seconds after the last renewal whether the socket is open
/// or not, and this timer is what stops that being us.
///
/// **No policy lives here.** Every decision this protocol makes — who may hold the block,
/// when it dies, what each reply means — is in `AgentAttentionCore` and is unit-tested
/// without root, a socket, or a wait. This file is the wire and the timer, and it exists
/// only because those two things cannot be tested.
///
/// **What a transport failure is reported as.** `PowerError` is the daemon's vocabulary and
/// has no case for "the daemon could not be reached", so an unreachable, silent, or
/// unintelligible daemon is reported as `.unknown` — "we do not know what happened", which
/// is exactly true. It is deliberately not `.pmsetFailed`: that case names a privileged
/// operation which, on these paths, was never attempted, and it would send whoever reads
/// the log off to debug `pmset` on a machine where the daemon simply is not running.
/// `PowerError.assertionFailed` exists in Core for the same reason in the other direction.
///
/// **Threading.** One serial queue guards everything: the descriptor, the holding flag, the
/// timer, and every byte on the wire. `acquire()` and `release()` are synchronous and hop
/// onto it; the renew timer targets it, so its handler is already on it and must never
/// `sync` back. `onLost` is the one thing outside that rule — it is set and called on the
/// main thread, so no lock guards it and none is needed.
final class PowerLeaseClient {
    /// Where the daemon listens. The same literal appears in the LaunchDaemon plist, which
    /// is what creates the socket; launchd sets its owner and mode before this app can
    /// reach it, so nothing here binds, unlinks, or otherwise races for the path.
    static let socketPath = "/var/run/dev.agentwarden.powerd.sock"

    /// How long one request-and-reply exchange may take before the connection is given up
    /// as dead.
    ///
    /// Bounded above by `PowerLease.renewInterval` (10s): a renewal that stalled past the
    /// next renewal's due time would pile heartbeats up behind each other instead of
    /// reporting the loss, and the lease would die at `PowerLease.expiry` with the app still
    /// insisting roam was on. The read loop below re-checks this deadline once a second, so
    /// the true worst case is 5s + one 1s slice = 6s, still inside the 10s interval.
    ///
    /// Bounded below by the daemon's slowest honest answer, which is `acquire`: it runs
    /// `pmset -a disablesleep 1` and then reads the setting back with `pmset -g` — two
    /// fork/exec round trips — and it does that behind a serial state queue shared with up
    /// to seven other connections. 5s leaves that room several times over.
    private static let exchangeDeadline: TimeInterval = 5

    /// How long a single `read` or `write` may block before the loop re-checks
    /// `exchangeDeadline`. Not a failure in itself: an expired slice is retried, because a
    /// daemon that has not answered in one second has not thereby gone away. It only sets
    /// how far past the deadline an exchange can run, which is at most one slice.
    private static let ioSlice = timeval(tv_sec: 1, tv_usec: 0)

    /// Called on the main thread when the lease is lost for any reason other than our own
    /// `release()`: the daemon died, the connection ended, or a renewal was refused. Never
    /// a silent degradation — losing the block means the next lid close sleeps the machine,
    /// and the user has to be told before that happens rather than after.
    ///
    /// Set it before the first `acquire()`. It is read on the main thread and nowhere else,
    /// which is why it carries no lock: the renewal runs on `queue` but hops to main before
    /// touching this.
    ///
    /// The handler must tolerate being called about a lease the caller has already given
    /// up. A `release()` that arrives just after a renewal has already failed still lets
    /// that failure through, because it really did happen — reporting a loss a moment late
    /// is honest, and suppressing it would not be.
    var onLost: (() -> Void)?

    /// Serializes the descriptor, `isHolding`, the timer, and the wire. `PowerLeaseClient`
    /// has no lock of its own; this queue is the lock.
    private let queue = DispatchQueue(label: "dev.agentwarden.roam.lease")

    /// The connection, or -1 when there is none. Guarded by `queue`.
    private var fd: Int32 = -1

    /// The heartbeat, alive exactly as long as the lease is. Guarded by `queue`.
    private var renewTimer: DispatchSourceTimer?

    /// Whether the lease is ours right now. Guarded by `queue`; read through `holding`.
    private var isHolding = false

    /// Whether the lease is held, as of the instant this is read.
    ///
    /// **This blocks, and must not be called from the main thread.** It is not a cheap flag
    /// read: it waits for `queue`, so a renewal already in flight holds it up for as long as
    /// that exchange takes — up to `exchangeDeadline` plus a slice. Reading it while
    /// rendering a menu would freeze the UI for seconds at a time. Cache it off-main and
    /// redraw from `onLost` instead.
    ///
    /// A snapshot, not a subscription: the daemon can take the lease away between this
    /// answer and the caller acting on it, which is what `onLost` is for. Must not be called
    /// from `queue` either — nothing that runs there is reachable from outside this type, so
    /// that cannot happen by accident.
    var holding: Bool { queue.sync { isHolding } }

    /// Take the lease, or report why not, leaving nothing half-open either way.
    ///
    /// **Precondition: not the main thread.** This blocks for the length of two exchanges,
    /// each bounded by `exchangeDeadline`, so up to about twelve seconds. The nominal path
    /// is not free either: the daemon answers `acquire` only after two `pmset` fork/execs,
    /// behind a serial state queue it shares with up to seven other connections, so hundreds
    /// of milliseconds is the *expected* cost, not the pathological one. This app runs
    /// `.accessory`, so its run loop is its only UI thread and every one of those
    /// milliseconds is frozen UI. Call this off-main and hop the `Result` back.
    ///
    /// The deadline is not the thing to shorten if that stall is unwelcome — a shorter one
    /// would start failing legitimate `pmset` round trips, which is a worse failure than a
    /// slow one. The shape is what to change.
    ///
    /// Idempotent: calling it while already holding returns success without opening a
    /// second connection, which would leak the first descriptor and leave the daemon
    /// counting two peers where there is one app.
    func acquire() -> Result<Void, PowerError> {
        return queue.sync { acquireOnQueue() }
    }

    /// Give the lease back, and say whether the daemon confirmed it.
    ///
    /// The answer matters where the machine is about to be put to sleep deliberately: an
    /// unconfirmed release means `SleepDisabled` may still be set, and a machine told to
    /// sleep while that setting stands will simply refuse. Where roam is only being switched
    /// off the answer changes nothing, so this is `@discardableResult` — the value is there
    /// for the caller that needs it, not a demand on the one that does not.
    ///
    /// `true` means one of exactly two things: the daemon **confirmed** the release, or this
    /// client was not holding a lease to begin with. Anything else is `false` — including,
    /// and this is the case worth stating, a lease that has already expired: the daemon
    /// answers `release` on a lease it no longer tracks with `error nolease`, which is not
    /// `.ok` and so reports `false` here.
    ///
    /// So `false` does not mean "the block is definitely still set" and `true` does not mean
    /// "the block is definitely clear". Neither is a claim about the machine-wide setting,
    /// which only the daemon can read. A caller deciding whether to sleep the machine should
    /// read `false` as *unconfirmed* and refuse to sleep on it — the conservative direction,
    /// because sleeping a machine that will not stay asleep is worse than not sleeping it.
    ///
    /// **Precondition: not the main thread**, for the same reason as `acquire()`. One
    /// exchange, so at worst about six seconds against a daemon that has stopped answering.
    /// The connection is torn down either way — an unanswered release still ends the lease,
    /// because the daemon drops one whose holder disconnects.
    @discardableResult
    func release() -> Bool {
        return queue.sync {
            guard isHolding else { return true }
            let confirmed = exchange(.release) == .ok
            // Cleared before the connection goes, and on the same serial queue the renewal
            // runs on, so a heartbeat cannot slip in behind this and report a loss for a
            // lease that was given up on purpose.
            isHolding = false
            teardown()
            return confirmed
        }
    }

    /// Caller must already be on `queue`.
    private func acquireOnQueue() -> Result<Void, PowerError> {
        guard !isHolding else { return .success(()) }
        guard connect() else { return .failure(.unknown) }

        guard let greeting = exchange(.hello(version: PowerProtocolVersion.current)) else {
            teardown()
            return .failure(.unknown)
        }
        switch greeting {
        case .okVersion:
            // Acceptance, not equality, is the handshake. The daemon answers `error version`
            // to a version it will not speak and reports its own on success, which may be
            // newer than ours. Insisting the numbers match would refuse an upgraded daemon
            // that still speaks version 1 — turning a compatible pair into a failed roam.
            break
        case .error(let error):
            teardown()
            return .failure(error)
        default:
            // `ok`, `held` or `free` in answer to `hello` is not this protocol. Whatever is
            // on the other end, it is not something to hand the machine's sleep behaviour to.
            teardown()
            return .failure(.unknown)
        }

        guard let granted = exchange(.acquire) else {
            teardown()
            return .failure(.unknown)
        }
        switch granted {
        case .ok:
            isHolding = true
            startRenewing()
            return .success(())
        case .error(let error):
            // `busy`, `foreign` and `unverified` all arrive here and are all passed through
            // untouched. Each names a different thing for the user to do about it, and
            // flattening them into one failure would take that away.
            teardown()
            return .failure(error)
        default:
            teardown()
            return .failure(.unknown)
        }
    }

    /// Open the connection and satisfy ourselves that root is on the other end.
    ///
    /// **The peer must be uid 0**, which is the mirror image of the daemon's own check: it
    /// refuses any connection that is not from the installing user, and this refuses any
    /// connection that is not from root. Note that the socket *file* is owned by the
    /// installing user — launchd creates it that way so this app can reach it — so its
    /// ownership proves nothing about who is serving it. `getpeereid` is the only thing that
    /// does, and it asks the kernel about the process on the other end rather than about a
    /// path that could have changed underneath us.
    ///
    /// Every failure past the descriptor being opened goes through `teardown()`, so this
    /// never returns false with a socket still open.
    ///
    /// Caller must already be on `queue`.
    private func connect() -> Bool {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            // POSIX returns -1 here, but the invariant "`fd` is -1 when there is no
            // connection" is what `exchange` and `teardown` read, so it is set rather than
            // assumed.
            fd = -1
            return false
        }
        // A peer that goes away between our write and its read would otherwise deliver
        // SIGPIPE, whose default disposition is death, and a menu-bar watcher must not die
        // because a daemon restarted. Nothing in this app disables SIGPIPE process-wide —
        // the only two places that do are `BridgeSocketServer`/`BridgeSocketClient` and the
        // daemon's own `main`, none of which run in this process — and the per-socket
        // option is the better fix regardless: it cannot be undone by another component
        // changing the process-wide disposition back.
        var enabled: Int32 = 1
        let noSignal = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                                  &enabled, socklen_t(MemoryLayout<Int32>.size))
        // Per-call deadlines on both directions. Without them a wedged daemon would block
        // this queue for ever, and the renew timer — which runs on that same queue — would
        // never fire again, so the app would go on believing it held a lease that had long
        // since expired.
        var slice = PowerLeaseClient.ioSlice
        let readDeadline = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                                      &slice, socklen_t(MemoryLayout<timeval>.size))
        let writeDeadline = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO,
                                       &slice, socklen_t(MemoryLayout<timeval>.size))
        // Checked rather than hoped for. None of the three can realistically fail on a
        // socket this function created two statements ago — the descriptor is valid, all
        // three are `SOL_SOCKET` options Darwin implements, and the sizes are exact — but
        // the comments above claim two protections, and a claim worth writing down is worth
        // verifying. A socket that could not be given them is not one to hand the machine's
        // sleep behaviour to: without `SO_NOSIGPIPE` a restarting daemon kills this process,
        // and without the deadlines every "bounded" exchange below is unbounded.
        guard noSignal == 0, readDeadline == 0, writeDeadline == 0 else {
            teardown()
            return false
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        // `sockaddr_un` is zero-initialised above, and the copy is bounded one short of the
        // field, so the path is always terminated. `socketPath` is a compile-time constant
        // of 36 bytes against Darwin's 104-byte `sun_path`, so this cannot truncate — which
        // matters, because a silently truncated path is a different path.
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            PowerLeaseClient.socketPath.withCString { source in
                strncpy(UnsafeMutableRawPointer(field).assumingMemoryBound(to: CChar.self),
                        source, capacity)
            }
        }
        // `connect` is the one call in this file that `SO_SNDTIMEO` does not bound, and
        // leaving it blocking would put a hole straight through this type's thesis. For an
        // AF_UNIX stream socket a full listen backlog makes `connect` wait for a slot — and
        // the daemon's accept loop takes its state queue to hand out a connection id
        // (`claimConnectionID`), so a daemon wedged on that queue stops accepting, the
        // backlog fills, and a blocking `connect` here would hold `queue` for ever and stop
        // the renew timer that runs on it. That is the wedged-daemon case this file exists
        // to survive, arriving through the front door.
        //
        // So: connect non-blocking, wait on `poll` against the same deadline every other
        // exchange uses, then put the socket back into blocking mode — every read and write
        // below depends on blocking-plus-`SO_RCVTIMEO` semantics, and left non-blocking they
        // would spin hot instead of waiting.
        let openFlags = fcntl(fd, F_GETFL, 0)
        guard openFlags >= 0, fcntl(fd, F_SETFL, openFlags | O_NONBLOCK) == 0 else {
            teardown()
            return false
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        if connected != 0 {
            // Captured on the very next line, before anything else runs: `errno` is only
            // meaningful until the next call that might set it, and building a `Date` for
            // the deadline first would be exactly such a call.
            let code = errno
            // A local socket usually connects or refuses immediately; `EINPROGRESS` is the
            // backlog case above and the only one worth waiting out.
            guard code == EINPROGRESS else {
                teardown()
                return false
            }
            let deadline = Date().addingTimeInterval(PowerLeaseClient.exchangeDeadline)
            guard awaitConnection(by: deadline) else {
                teardown()
                return false
            }
        }
        guard fcntl(fd, F_SETFL, openFlags) == 0 else {
            teardown()
            return false
        }

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == 0 else {
            teardown()
            return false
        }
        return true
    }

    /// Wait for a non-blocking `connect` to finish, or give up at the deadline.
    ///
    /// Caller must already be on `queue`, with the socket still in non-blocking mode.
    private func awaitConnection(by deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var watched = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&watched, 1, Int32(remaining * 1000))
            if ready < 0 {
                // A signal is not an answer. Anything else is.
                if errno == EINTR { continue }
                return false
            }
            // Zero means the deadline passed with the socket still not writable.
            guard ready > 0 else { return false }
            // Writable is not the same as connected: a refusal also wakes `poll`, and the
            // actual outcome is in `SO_ERROR`. Reading it is the only way to tell the two
            // apart — treating writability as success would hand back a dead socket.
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length) == 0,
                  failure == 0 else { return false }
            return true
        }
    }

    /// Stop renewing and close the connection. Idempotent.
    ///
    /// Safe to call from the renew handler: cancelling a dispatch source from the queue it
    /// targets is guaranteed to prevent any further invocation of its handler, and every
    /// call site here is on `queue`.
    ///
    /// Closing the descriptor is itself a release as far as the daemon is concerned — it
    /// drops the lease when the holder disconnects — so tearing down can never leave the
    /// machine blocked awake with nothing holding it.
    ///
    /// Caller must already be on `queue`.
    private func teardown() {
        renewTimer?.cancel()
        renewTimer = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// Start the heartbeat that keeps the lease alive.
    ///
    /// `PowerLease.renewInterval` against the daemon's `PowerLease.expiry` — both taken from
    /// Core and never re-typed here — leaves room for three missed beats before the block is
    /// dropped, so a momentarily busy machine does not lose a roam session over one late
    /// timer.
    ///
    /// **`.strict`, and that flag is load-bearing.** By default this timer is deferrable:
    /// `dispatch/source.h` says of `dispatch_source_set_timer` that "any fire of the timer
    /// may be delayed by the system in order to improve power consumption and system
    /// performance", with "the lower limit ... under the control of the system". During roam
    /// this app is the exact profile that invites such deferral — no windows, not frontmost,
    /// display off, nothing user-visible happening. A heartbeat deferred past the daemon's
    /// 45-second expiry means the daemon clears `SleepDisabled`, the closed lid sleeps the
    /// machine, and the user's session dies — the precise outcome this whole feature exists
    /// to prevent, arriving silently at the only moment it matters, with `onLost` reporting
    /// it only whenever the timer eventually runs. `DISPATCH_TIMER_STRICT` is the documented
    /// opt-out: "the system should make a best effort to strictly observe the leeway value
    /// specified ... even if that value is smaller than the default leeway that would be
    /// applied to the timer otherwise."
    ///
    /// That header also cautions that the flag "may override power-saving techniques
    /// employed by the system and cause higher power consumption ... only when absolutely
    /// necessary". It is warranted here and the cost is negligible: this fires at 0.1 Hz and
    /// does six bytes of local socket I/O, against a feature whose failure mode is losing
    /// the user's work.
    ///
    /// **What `.strict` does not settle.** It addresses deferral of *this timer*. Whether an
    /// `.accessory` app is throttled or suspended wholesale under App Nap is a separate
    /// question, and a process-wide opt-out (`ProcessInfo.beginActivity`) is session-scoped
    /// state that belongs with the roam lifecycle rather than in a socket client. See the
    /// Task 9 report for the evidence and the recommendation. What is settled is that the
    /// idle-sleep assertion does *not* cover this: `IOPMLib.h` scopes
    /// `kIOPMAssertPreventUserIdleSystemSleep` to "prevents the system from sleeping
    /// automatically due to a lack of user activity" and says nothing about scheduling.
    ///
    /// Caller must already be on `queue`.
    private func startRenewing() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + PowerLease.renewInterval,
                       repeating: PowerLease.renewInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Already on `queue` — the source targets it — so nothing here needs
            // synchronising and nothing here may `sync` back onto it.
            guard self.isHolding else { return }
            guard self.exchange(.renew) == .ok else {
                // The order matters: stop holding, then stop the heartbeat and close, then
                // tell the app. Cleared first so nothing can observe a client that claims
                // the lease over a connection that has gone.
                self.isHolding = false
                self.teardown()
                // `async`, never `sync`. A caller sitting in `acquire()` or `release()` is
                // blocked on this very queue, and a synchronous hop to the main thread
                // would deadlock against it. Hopping at all is what lets `onLost` be
                // main-thread-only and therefore lock-free.
                DispatchQueue.main.async { [weak self] in self?.onLost?() }
                return
            }
        }
        timer.resume()
        renewTimer = timer
    }

    /// One request, one reply, within one deadline.
    ///
    /// `nil` is any answer we could not read: a failed write, a closed connection, silence
    /// past the deadline, or a line this protocol does not define. Every caller treats it as
    /// fatal to the connection, and that is not caution — after a half-finished exchange the
    /// stream is out of step, and a client that carried on would read the previous reply as
    /// the answer to its next request and could hold a lease the daemon had refused.
    ///
    /// Caller must already be on `queue`.
    private func exchange(_ request: PowerRequest) -> PowerReply? {
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(PowerLeaseClient.exchangeDeadline)
        guard writeAll(Data((request.wire + "\n").utf8), by: deadline) else { return nil }
        return readReply(by: deadline)
    }

    /// Write the whole frame or give up. A short write is the normal case, not an error.
    ///
    /// Caller must already be on `queue`.
    private func writeAll(_ payload: Data, by deadline: Date) -> Bool {
        var sent = 0
        return payload.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while sent < payload.count {
                guard Date() < deadline else { return false }
                let written = Darwin.write(fd, base.advanced(by: sent), payload.count - sent)
                if written > 0 {
                    sent += written
                    continue
                }
                // Zero is neither progress nor an error `errno` describes, so it is refused
                // outright: retrying on it would spin this loop against the deadline while
                // reading a stale `errno` from some earlier call.
                guard written < 0 else { return false }
                // A signal interrupting the write, or the send slice expiring, is not the
                // daemon going away. Only the deadline above is entitled to decide that.
                // (EWOULDBLOCK is the same value as EAGAIN on Darwin.)
                let code = errno
                guard code == EINTR || code == EAGAIN else { return false }
            }
            return true
        }
    }

    /// Read one newline-terminated reply, or nil.
    ///
    /// Caller must already be on `queue`.
    private func readReply(by deadline: Date) -> PowerReply? {
        var pending = Data()
        // Longer than any reply this protocol defines — the longest, `held 45 unknown` plus
        // its newline, is sixteen bytes — so the whole line normally arrives in one read,
        // and the loop below is for the case where it does not.
        var chunk = [UInt8](repeating: 0, count: 64)
        while Date() < deadline {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN { continue }
                return nil
            }
            // Zero is EOF: the daemon closed on us, which also means the lease is gone.
            guard count > 0 else { return nil }
            pending.append(contentsOf: chunk[0..<count])
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                // A line the protocol does not define is nil, and therefore fatal to the
                // connection, exactly like silence. Parsing is Core's job and is tested
                // there; this only decides what to do with the answer.
                return PowerReply.parse(line)
            }
            // Bounded. The peer is root and so already trusted with far more than this, but
            // a peer that has sent 256 bytes without a newline is not speaking this
            // protocol, and buffering on its say-so would trade a lost lease for a stuck
            // client that never reports anything at all.
            guard pending.count < 256 else { return nil }
        }
        return nil
    }

    /// Last resort. A client dropped without `release()` would otherwise leave the
    /// descriptor open, and the daemon would hold the machine awake until the lease expired
    /// `PowerLease.expiry` seconds later. Closing the connection ends it in about a second
    /// instead, because the daemon drops a lease whose holder disconnects.
    ///
    /// It does not send `release` first: blocking on a socket inside `deinit` is a hazard
    /// worth avoiding, and the disconnect is a release in its own right.
    ///
    /// No `queue.sync` here, and none is needed. `deinit` runs only once the last strong
    /// reference is gone, and the renew handler takes a strong one (`guard let self`) before
    /// touching anything, so no other thread can be inside this object. A `sync` would be
    /// worse than redundant: were the last reference ever released on `queue`, it would
    /// deadlock.
    deinit {
        renewTimer?.cancel()
        renewTimer = nil
        if fd >= 0 { close(fd) }
    }
}
