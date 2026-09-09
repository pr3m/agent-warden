import Foundation
import IOKit.ps
import AgentAttentionCore

/// What happened when roam was asked to start.
///
/// Four outcomes rather than a `Bool`, because the three ways of not starting mean different
/// things to whoever asked: one is already-done, one is wait-a-moment, and one is a refusal
/// with a reason the user can act on.
enum RoamEntry: Equatable {
    /// Roam is established: the idle assertion is held, the daemon granted the lease, and
    /// `roam.json` is on disk.
    case entered
    /// Roam was already on. Nothing was asked of the daemon and nothing changed.
    case alreadyOn
    /// An earlier `enter` or `exit` is still waiting on the daemon. Nothing was done; the
    /// answer will arrive through `onChange`, and asking again after that will work.
    case busyChanging
    /// Roam did not start and nothing was left applied.
    ///
    /// Usually the daemon's own word for why — `busy`, `foreign` and `unverified` each name a
    /// different thing to do about it — and `assertionFailed` when the refusal came from this
    /// side, the kernel having declined the idle-sleep assertion before the daemon was asked
    /// anything at all. Core keeps that case separate for exactly this reason.
    case refused(PowerError)
}

/// Roam, from the app's side: enter it, leave it, and end it before the battery does.
///
/// Everything *decidable* lives in `AgentAttentionCore` and is unit-tested without root, a
/// socket or a wait — the lease rules, the battery policy, the hotspot classification, the
/// liveness rule. This class is the wiring, and deliberately holds no policy of its own.
///
/// **Threading.** Every stored property here is read and written on the main thread only, and
/// every callback fires there. The two exceptions are `PowerLeaseClient.acquire()` and
/// `release()`, which both document "precondition: not the main thread": they block for the
/// length of one or two bounded socket exchanges — about twelve and six seconds respectively
/// against a daemon that has stopped answering, and hundreds of milliseconds on the nominal
/// path, because the daemon answers `acquire` only after two `pmset` fork/execs. This app runs
/// `.accessory`, so its run loop is its only UI thread and every one of those milliseconds is
/// frozen UI. They run on `leaseQueue` and hop their answers back to main, which is why `enter`
/// takes a completion instead of returning a value.
///
/// **What is on disk and when.** `roam.json` exists if and only if roam is fully established —
/// the assertion held, the lease granted. Every path that ends roam removes the file before it
/// starts giving anything back, so a reader never finds a file claiming a session that is being
/// torn down. A failure part-way through `enter` leaves no file at all.
final class RoamService {
    /// Called on the main thread whenever roam state changes, so the bubble and the menus can
    /// redraw. Losing the lease is a change like any other and must be visible.
    var onChange: (() -> Void)?

    /// One line for a person, on the main thread.
    ///
    /// **Deliberately not a notification API.** This app has never posted an OS notification —
    /// it says things through the panel's status line (`AttentionPanelController.flash`), the
    /// chime, local speech and the log — and the brief's `NSUserNotification` sketch is both
    /// deprecated and a second mechanism. So this type does not choose a surface: it hands
    /// `AppDelegate` a sentence and `AppDelegate` says it the way this app already says things.
    var onNotice: ((String) -> Void)?

    /// The app's log. Assigned by `AppDelegate` after `super.init()`, because the log is an
    /// instance method there and `self` is not available before then.
    var log: (String) -> Void = { _ in }

    private let paths: AppPaths
    private let assertion = SleepAssertion()
    private let lease = PowerLeaseClient()

    /// Where `acquire()` and `release()` run. Serial, so a release cannot overtake the acquire
    /// it belongs after; `.userInitiated` because somebody is waiting on the answer with a menu
    /// open.
    private let leaseQueue = DispatchQueue(label: "dev.agentwarden.roam.service",
                                           qos: .userInitiated)

    /// The established session, or nil. Main thread only.
    private var state: RoamState?

    /// The process-wide power-management opt-out held for the length of the session. See
    /// `beginActivity()`.
    private var activity: NSObjectProtocol?

    /// True while a lease call is in flight. Guards against a second `enter` opening a second
    /// connection, and against an `exit` racing the `enter` it would be undoing.
    private var settling = false

    init(paths: AppPaths) {
        self.paths = paths
        lease.onLost = { [weak self] in self?.leaseLost() }
    }

    /// Is roam established right now?
    ///
    /// An in-memory read, and specifically **not** `PowerLeaseClient.holding`, which blocks on
    /// the client's own queue behind any renewal in flight. This is the one safe to call while
    /// drawing a menu.
    var isActive: Bool { state != nil }

    /// Is a request to the daemon outstanding? A toggle should be disabled while this is true —
    /// `enter` and `exit` both refuse to act on top of one.
    var isChanging: Bool { settling }

    /// The session as it stands, for anything that wants to show when it started or which
    /// hotspot it believes it is on.
    var current: RoamState? { state }

    /// Throw away roam state left behind by a previous run. Called once, at launch.
    ///
    /// **Never adopted.** A `roam.json` found at startup was written by a process that is gone,
    /// and whatever it says, nothing is holding the machine awake now: the idle assertion died
    /// with that process and the daemon dropped the lease when its socket closed. Re-entering
    /// roam disables the machine's sleep, which is a thing to do because somebody asked, not
    /// because a file survived a crash.
    func discardStaleState() {
        guard FileManager.default.fileExists(atPath: paths.roamFile.path) else { return }
        removeStateFile()
        log("discarded roam state left by a previous run — roam does not resume by itself")
    }

    /// Enter roam, or fail without leaving anything half-applied.
    ///
    /// The lease is the gate. The idle assertion alone is not roam: `IOPMLib.h` says of
    /// `kIOPMAssertPreventUserIdleSystemSleep` that "the system may still sleep for lid close",
    /// so without the machine-wide block a closed lid still sleeps the Mac — and saying "roam is
    /// on" would be the one lie this feature must not tell. A refused `acquire` therefore gives
    /// the assertion back, ends the activity, and writes no state file.
    ///
    /// - Parameters:
    ///   - hotspot: what the caller believes the network is, recorded for the status surfaces.
    ///     Best-effort and never a gate — see `RoamNetwork`.
    ///   - onBattery: whether the machine was unplugged at entry. Recorded, not acted on.
    ///   - completion: called on the main thread, always, exactly once.
    func enter(hotspot: RoamHotspot?, onBattery: Bool,
               completion: @escaping (RoamEntry) -> Void) {
        guard state == nil else { completion(.alreadyOn); return }
        guard !settling else { completion(.busyChanging); return }

        // Taken first because it is instant and local: if the kernel refuses it there is nothing
        // to undo and no reason to have troubled the daemon.
        guard assertion.take() else {
            log("roam refused: the kernel did not grant the idle-sleep assertion")
            completion(.refused(.assertionFailed))
            return
        }
        beginActivity()
        settling = true
        onChange?()                     // a UI can show the transition and stop offering the toggle

        // Captured strongly on purpose. If this service is deallocated while the call is out,
        // the closure still holds the only reference to the client, and releasing it afterwards
        // runs `PowerLeaseClient.deinit`, which closes the socket — and a lease whose holder
        // disconnects is one the daemon drops. Nothing is left holding the machine awake.
        let lease = self.lease
        leaseQueue.async {
            let outcome = lease.acquire()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.settling = false
                switch outcome {
                case .failure(let error):
                    self.assertion.release()
                    self.endActivity()
                    self.log("roam refused: \(error.rawValue)")
                    self.onChange?()
                    completion(.refused(error))
                case .success:
                    let pid = ProcessInfo.processInfo.processIdentifier
                    let now = Date()
                    self.state = RoamState(
                        active: true,
                        startedAt: now,
                        ownerPID: pid,
                        // Stamped so `RoamState.isLive` can reject a recycled PID: a pid on its
                        // own is reused within hours, and a reader that trusted it would call a
                        // stranger's process the owner of a roam session. A probe that cannot
                        // answer leaves 0 here, which no live process matches.
                        ownerPIDStartedAt: ProcessProbe.snapshot(pid: pid)?.startedAt ?? 0,
                        leaseRenewedAt: now,
                        enteredOnBattery: onBattery,
                        hotspot: hotspot
                    )
                    self.persist()
                    self.log("roam on\(onBattery ? " (on battery)" : "")"
                             + (hotspot.map { ", network: \($0.kind)" } ?? ""))
                    self.onChange?()
                    completion(.entered)
                }
            }
        }
    }

    /// Leave roam because somebody asked to.
    ///
    /// The session is torn down in memory and on disk **before** the lease goes back, not after:
    /// giving the lease back takes a socket round trip, and for those seconds a `roam.json`
    /// saying roam is on would be telling a status reader the machine is protected while the
    /// block is being dropped. The other order is the dangerous one.
    func exit() {
        guard state != nil else { return }
        guard !settling else {
            log("roam: ignoring an exit while a power request is still out")
            return
        }
        settling = true
        assertion.release()
        endActivity()
        clearSession()
        log("roam off")

        let lease = self.lease
        leaseQueue.async {
            let confirmed = lease.release()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.settling = false
                // `false` means unconfirmed, never "there was nothing to release" — an expired
                // lease answers `error nolease` and lands here too. It is logged rather than put
                // in front of the user because the connection is torn down either way, and the
                // daemon clears the block for a holder that disconnects. The battery guard, which
                // cannot wait to find that out, treats the same answer very differently.
                if !confirmed {
                    self.log("roam off: the daemon did not confirm the release; the block should "
                             + "clear as the connection closes. Check with: pmset -g | grep SleepDisabled")
                }
                self.onChange?()
            }
        }
    }

    /// The app is quitting.
    ///
    /// No `lease.release()` here. It blocks the main thread for up to six seconds at the one
    /// moment nothing may block, and it is not needed: the daemon drops a lease whose holder
    /// disconnects, and this process's socket closes as it exits. What must happen here is
    /// local — end the activity token, which is process-wide and pairs with `beginActivity`,
    /// and take the file away so nothing reports a session that ended with the app.
    func shutdown() {
        guard state != nil else { return }
        assertion.release()
        endActivity()
        state = nil
        removeStateFile()
        log("roam ended: Agent Warden is quitting")
    }

    /// Driven by `AppDelegate`'s existing sweep. No new timer.
    ///
    /// - Parameters:
    ///   - reading: the machine's power situation, from `PowerProbe.read()`.
    ///   - threshold: `AttentionConfig.roamBatteryThreshold`, already clamped by `validated()`.
    func tick(reading: PowerReading, threshold: Int) {
        guard state != nil, !settling else { return }

        // Refreshed so a reader can tell a live session from a file left behind by a crash.
        //
        // Precisely what this stamp means: *this process was alive and still believed it held
        // the lease, at this instant*. It is not the lease's own renewal — that is the client's
        // 10-second `.strict` heartbeat, and a failed one clears this session through `onLost`
        // before the next sweep arrives. `RoamState.isLive` reads it against a 45-second window
        // (`PowerLease.expiry`), which the default 15-second sweep keeps comfortably inside. A
        // hand-edited `sweepIntervalSeconds` above 45 would make a live session read as dead
        // here; that is a limit of hanging this off the existing sweep rather than a new timer.
        state?.leaseRenewedAt = Date()
        persist()

        switch RoamPolicy.guardAction(reading: reading, threshold: threshold, roamActive: true) {
        case .none:
            return
        case .exitAndSleep(let percent):
            endForBattery(percent: percent)
        }
    }

    /// The battery is low enough that roam has to end itself.
    ///
    /// **The order is the specification and is not decoration:** tell the user, then give the
    /// lease back and find out whether that was confirmed, then drop the assertion, then ask the
    /// machine to sleep and check the answer. A notice posted after `IOPMSleepSystem` is one
    /// nobody sees; a sleep requested while the machine-wide block may still stand is a machine
    /// that simply stays awake on a dying battery, having told its owner it was asleep.
    private func endForBattery(percent: Int) {
        let notice = "Battery at \(percent)% — ending roam and sleeping your Mac to save your work."
        onNotice?(notice)
        log("battery guard: \(percent)% on battery — \(notice)")

        settling = true
        clearSession()

        let lease = self.lease
        leaseQueue.async {
            let released = lease.release()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.settling = false
                self.assertion.release()
                self.endActivity()
                // `false` is *unconfirmed*, not "nothing to release": an expired lease answers
                // `error nolease` and arrives here. Neither answer is a claim about the
                // machine-wide setting, which only the daemon can read — so on `false` we must
                // not act as though the block were clear. Sleeping a Mac that will refuse to
                // stay asleep is worse than not sleeping it, and worse still if we then say we
                // did.
                guard released else {
                    let warning = "Roam ended, but the sleep block could not be confirmed as "
                        + "cleared, so your Mac was left awake. Clear it with: "
                        + "sudo pmset -a disablesleep 0"
                    self.log("battery guard: " + warning)
                    self.onNotice?(warning)
                    return
                }
                if !SystemSleep.now() {
                    let warning = "Roam ended, but macOS refused the request to sleep."
                    self.log("battery guard: " + warning)
                    self.onNotice?(warning)
                }
            }
        }
    }

    /// The lease went away without us asking: the daemon died, the connection ended, or a
    /// renewal was refused. The user finds out from the app, not from a flat battery.
    ///
    /// Guarded on roam still being active because there is a known race, documented on
    /// `PowerLeaseClient.onLost`: a renewal can fail in the same instant a deliberate `release()`
    /// is in flight, and the client reports that failure honestly because it really happened. By
    /// then `exit` has already cleared the session, so this returns without a word — telling
    /// somebody roam collapsed a moment after they switched it off would be worse than silence.
    private func leaseLost() {
        guard state != nil else { return }
        assertion.release()
        endActivity()
        clearSession()
        let notice = "Roam ended: the power helper stopped holding the sleep block. "
            + "Closing the lid will now sleep your Mac."
        log(notice)
        onNotice?(notice)
    }

    /// Forget the session in memory and on disk, and say so. Deliberately touches neither the
    /// lease nor the assertion: each caller has its own order for those, and that order is the
    /// part that matters.
    private func clearSession() {
        state = nil
        removeStateFile()
        onChange?()
    }

    private func removeStateFile() {
        do {
            try FileManager.default.removeItem(at: paths.roamFile)
        } catch CocoaError.fileNoSuchFile {
            // Already gone is the wanted end state, not a failure.
        } catch {
            log("could not remove roam state at \(paths.roamFile.path): \(error)")
        }
    }

    /// Write the session out, atomically and mode 0600 — the same discipline as `pairings.json`,
    /// `state.json` and `app.json`, all of which take `AtomicFile.write`'s default permissions.
    private func persist() {
        guard let state else { return }
        do {
            try AtomicFile.write(JSONCoding.encoder.encode(state), to: paths.roamFile)
        } catch {
            // Reported and not fatal: the file is how *other* processes read roam, and this one
            // holds the assertion and the lease whether or not the write landed. Silently losing
            // it would leave `aa-status` saying roam is off during a live session.
            log("could not write roam state: \(error)")
        }
    }

    /// Tell the system this process is doing something a person started and is waiting on.
    ///
    /// `NSProcessInfo.h` describes these activities as hints in response to which "the system
    /// will disable some or all of the heuristics" it uses to save battery — which is exactly
    /// what a roaming app needs, because with no windows, nothing frontmost and the display off
    /// it is the textbook candidate for being throttled. The lease heartbeat that keeps the
    /// machine awake is a 10-second timer against a 45-second expiry, and a process whose timers
    /// are being deferred loses the block without ever being told.
    ///
    /// **Why `.userInitiatedAllowingIdleSystemSleep` and not `.userInitiated`.** The header
    /// defines them one line apart (`NSProcessInfo.h:155-156`):
    /// `NSActivityUserInitiated = (0x00FFFFFF | NSActivityIdleSystemSleepDisabled)` and
    /// `NSActivityUserInitiatedAllowingIdleSystemSleep = (NSActivityUserInitiated & ~NSActivityIdleSystemSleepDisabled)`.
    /// So `.userInitiated` would also hold idle sleep off — which `SleepAssertion` already does,
    /// through IOKit, with a name that shows up in `pmset -g assertions`. Two mechanisms for one
    /// guarantee is two places to forget to let go.
    ///
    /// The token is process-wide and **must be paired**: an unended one is a power opt-out that
    /// nothing ever ends. `RoamService` owns the session, so it owns the token; every path that
    /// ends roam — `exit`, `shutdown`, `leaseLost`, the battery guard — calls `endActivity()`.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Agent Warden roam: holding the sleep block while the lid is closed"
        )
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    /// The activity token must not outlive the object that took it. `NSProcessInfo.h` says an
    /// unended token is ended when it deallocates, so this is belt to that braces — the same
    /// pairing `SleepAssertion.deinit` makes for the assertion, written out for the same reason:
    /// a power opt-out nothing ends is one nobody can find.
    deinit { endActivity() }
}

// MARK: - Reading the battery

/// What the machine's power situation is, right now.
///
/// **IOKit rather than `pmset -g batt`.** This is read from `AppDelegate`'s sweep, on the main
/// thread, every `sweepIntervalSeconds` for as long as the app runs. `IOPSCopyPowerSourcesInfo`
/// is an in-process registry read; shelling out to `pmset` would be a fork, an exec and a parse
/// of human-readable output on the UI thread nearly six thousand times a day. It is also the
/// same framework `SleepAssertion` and `SystemSleep` already use, so it is not a new dependency.
///
/// **Every failure reports as "on AC, percent unknown", and that direction is deliberate.**
/// `RoamPolicy.guardAction` answers `.none` to both, so a reading we could not take can never
/// sleep the machine — the conservative answer, because a battery we cannot read is not an empty
/// one, and sleeping on a failed read would cause exactly the interruption the guard exists to
/// avoid.
enum PowerProbe {
    static func read() -> PowerReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerReading(percent: nil, onAC: true)
        }
        // The system-wide answer to "what is powering this machine", rather than one source's
        // view of itself. `IOPowerSources.h` documents exactly three possible values; only
        // "Battery Power" means the machine is spending a charge it cannot replace. A UPS reads
        // as external power here and so never trips the guard, which is the safe way round for a
        // machine whose internal battery is charging the whole time.
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onAC = providing != kIOPMBatteryPowerKey

        return PowerReading(percent: internalBatteryPercent(blob), onAC: onAC)
    }

    /// The internal battery's charge, or nil where there is not one to read — a desktop Mac, or
    /// a description that arrived without the two keys this needs. Nil is *not* zero.
    private static func internalBatteryPercent(_ blob: CFTypeRef) -> Int? {
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            // `IOPSKeys.h` warns that not every key is present in every description, so each one
            // is asked for rather than assumed, and a source missing any of them is skipped.
            guard description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey as String] as? Bool == true,
                  let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
                  maximum > 0 else { continue }
            // macOS reports these already normalised to 100 for an internal battery, but the
            // ratio is what the keys actually mean, and dividing costs nothing.
            return min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
        }
        return nil
    }
}
