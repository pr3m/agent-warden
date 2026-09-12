import AppKit
import AgentAttentionCore
import SystemConfiguration

/// Wires the file-backed event stream to the attention queue, the floating bubble and the alerts.
///
/// Everything the app *decides* lives in `AttentionEngine`; this class only does I/O, timing and
/// AppKit. That split is why the behaviour is testable without a screen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths: AppPaths
    private let store: EventStore
    private var config: AttentionConfig
    private var configModifiedAt: Date?
    private let engine: AttentionEngine
    private let panel = AttentionPanelController()
    private let bubble: BubbleController
    private let speech = SpeechAnnouncer()
    private let chimePlayer = SystemChimePlayer()
    private let contractWindow = ContractWindow()
    private lazy var chime = ChimeScheduler(player: chimePlayer)
    private let discovery = DiscoveryService()
    private let branches = BranchService()
    private let contextWindow = SessionContextWindow()
    /// The bridge host this app keeps running, and the focus endpoint it answers. See
    /// `BridgeService`.
    private let bridge: BridgeService
    private let pairings: PairingStore
    /// Asks one unlinked session's terminal to identify itself, off the main thread. See
    /// `TabAutoLinker` for why it is one at a time and why it stops asking.
    private let autoLinker: TabAutoLinker
    private let autoLinkQueue = DispatchQueue(label: "ai.wundamental.agent-warden.autolink")
    /// Keeps the name and the ⌘N number on each row matching what the tab bar actually says. See
    /// `TabTitleService` for why a title has to be re-read rather than remembered.
    private let tabTitles: TabTitleService
    /// Roam: the lid-closed session.
    ///
    /// **Not driven from the sweep.** It is started and stopped by `toggleRoam`, and once running
    /// it keeps its own time off the lease heartbeat — `RoamService.leaseRenewed`, every
    /// `PowerLease.renewInterval`, which is what stamps `roam.json` and runs the battery guard.
    /// The sweep was the original clock and was wrong twice over: `sweepIntervalSeconds` is
    /// user-editable up to an hour, and a `Timer` on the main run loop is deferrable in exactly
    /// the no-windows, display-off state roam runs in. `RoamService.leaseRenewed` carries the
    /// full reasoning. What the sweep still does is *render* — `roamMenuState` is recomputed on
    /// every draw — which is a different thing from driving.
    ///
    /// See `RoamService` for why every call to the power daemon leaves this thread to make it.
    private let roam: RoamService
    /// Whether the last `enter` attempt was refused because something other than this app
    /// already holds the machine's sleep block.
    ///
    /// There is no proactive way to learn this: unlike "the power helper is missing", which
    /// `roamMenuState` answers by checking whether the daemon's socket exists at all, a
    /// foreign hold on `SleepDisabled` is only visible to whoever asks the daemon — and
    /// asking is exactly what `enter` does. So this is learned by trying, remembered from the
    /// most recent attempt, and superseded the moment a new attempt reports anything else:
    /// see `toggleRoam`, the only writer.
    ///
    /// **Being the only writer is why `.foreign` has to stay clickable** (`RoamMenuText
    /// .isActionable`). Nothing re-checks this flag — the sweep cannot, because the only verbs
    /// that would answer are `acquire`, which would silently *take* the lease if it succeeded,
    /// and `status`, which would mean a second client opening a fresh blocking socket round
    /// trip every sweep for a state this rare. So with the item disabled, one `error foreign`
    /// made roam unavailable until the app was restarted, however long ago the user cleared the
    /// hold. A click is the cheap, honest re-check, and it lands here.
    private var roamForeignHold = false
    private lazy var pairingWindow = PairingWindow()
    /// The last completed registry scan, kept so the status interface can report its freshness.
    private var lastDiscovery: DiscoveryReport?

    /// Is the queue panel open? The bubble is always visible; this is only about the panel.
    /// Whether the list is on screen, and who put it there. The rule lives in
    /// `PanelPresentation`: only the user opens this window.
    private var presentation = PanelPresentation()
    private var isExpanded: Bool { presentation.isExpanded }
    /// Did the user open it deliberately? If so it stays open when the queue empties.

    private var statusItem: NSStatusItem?
    private let outsideClicks = OutsideClickWatcher()
    private var spoolWatcher: DirectoryWatcher?
    private var sessionWatcher: DirectoryWatcher?
    private var timer: Timer?

    override init() {
        paths = AppPaths.resolved()
        try? paths.createDirectories()
        store = EventStore(paths: paths)
        pairings = PairingStore(url: paths.pairingsFile)
        autoLinker = TabAutoLinker(ghostty: GhosttyAdapter(), pairings: pairings)
        tabTitles = TabTitleService(ghostty: GhosttyAdapter(), pairings: pairings)
        roam = RoamService(paths: paths)
        bridge = BridgeService(paths: paths)
        config = AttentionConfig.load(from: paths.configFile)
        bubble = BubbleController(size: CGFloat(config.bubbleSize))
        engine = AttentionEngine(
            config: config,
            clock: SystemClock(),
            liveness: SystemLiveness(),
            restoring: store.loadSnapshot()
        )
        super.init()
        tabTitles.onChange = { [weak self] in self?.render() }
        // Roam changing state is a redraw like any other — including the one nobody asked for,
        // where the lease is lost and the next lid close will sleep the machine.
        roam.onChange = { [weak self] in self?.render() }
        // What roam has to say goes out the way this app already says things: the panel's status
        // line, and the log. There is no second notification mechanism here and no OS banner —
        // this app has never posted one. Twenty seconds rather than the default six because
        // these sentences carry a command to type when something needs repairing.
        roam.onNotice = { [weak self] message in self?.panel.flash(message, seconds: 20) }
        roam.log = { [weak self] message in self?.log(message) }
        // Read through rather than pushed, so the guard cannot be running on a threshold this
        // object changed minutes ago — `config` is replaced wholesale by both a settings change
        // and a hand-edited file being reloaded. If this delegate is gone there is no live
        // configuration to speak for, and the shipped default is the safe answer.
        roam.batteryThreshold = { [weak self] in
            self?.config.roamBatteryThreshold ?? AttentionConfig.default.roamBatteryThreshold
        }
        speech.isEnabled = config.speechIsAudible
        speech.voiceIdentifier = config.speechVoiceIdentifier
        chime.isEnabled = config.chimeIsAudible
        configModifiedAt = fileModificationDate(paths.configFile)
    }

    // MARK: - Lifecycle

    /// The app coming forward is not a person asking to see the list.
    ///
    /// Wired deliberately, though it does nothing: an activation handler that exists and is a
    /// no-op is harder to turn into a window than one somebody adds later without knowing the rule.
    func applicationDidBecomeActive(_ notification: Notification) {
        presentation.applicationActivated()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        publishAppPresence()
        // Write the config out on first run. Without it there is no file to hand-edit and, more
        // importantly, nowhere for a dragged bubble position to live until something else happens
        // to save it.
        if !FileManager.default.fileExists(atPath: paths.configFile.path) {
            try? config.save(to: paths.configFile)
            configModifiedAt = fileModificationDate(paths.configFile)
        }
        // A roam.json from a previous run describes a session that ended with that process.
        // Re-entering roam disables the machine's sleep, and that happens because somebody asks.
        //
        // Read-during-startup is safe without any ordering against `discardStaleState` below: a
        // reader (`aa-roam status`/`indicator`) validates the file through `RoamState.isLive`,
        // which checks the *recorded owner process*, not the file's mere presence. A `roam.json`
        // left by a crashed run names a process that is already gone (that is what let
        // `SingleInstance` allow this launch at all), so `isLive` reads false whether or not this
        // line has run yet — and this instance cannot write a *fresh* file before this point,
        // because nothing here calls `enter` until a menu click asks for it, well after this
        // line. So there is no window in which a live session's file could be seen as stale, only
        // one in which an already-stale one is (correctly) seen as stale sooner.
        roam.discardStaleState()
        installStatusItem()
        wireBubble()
        wirePanelCallbacks()
        wireOutsideClicks()

        bubble.apply(placement: config.bubblePlacement, size: CGFloat(config.bubbleSize))
        if config.bubbleEnabled { bubble.show() }

        spoolWatcher = DirectoryWatcher(url: paths.spool) { [weak self] in self?.refresh() }
        sessionWatcher = DirectoryWatcher(url: paths.sessions) { [weak self] in self?.refresh() }
        spoolWatcher?.start()
        sessionWatcher?.start()

        // Sessions that were already running before we started are invisible to hooks until they
        // do something. Ask Claude Code's own registry who is out there.
        discovery.onReport = { [weak self] report in self?.applyDiscovery(report) }
        discovery.scan(force: true)

        // The transcript's branch is stamped at launch and never revisited. Read the directory.
        branches.onReading = { [weak self] fact, sessionID in
            guard let self else { return }
            if self.engine.apply(branch: fact, sessionID: sessionID) {
                self.render()
                self.persist()
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: config.sweepIntervalSeconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 2

        bridge.log = { [weak self] message in self?.log(message) }
        bridge.focusLinkedTab = { [weak self] sessionID, reply in
            guard let self else { return }
            self.focusForBridge(sessionID, reply: reply)
        }
        bridge.start()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? store.save(snapshot: engine.snapshot())
        // Leaving a stale presence file behind would make `aa-status` report a monitor that is not
        // there. The pid check would catch it, but saying nothing is cleaner than saying wrong.
        store.clearAppStatus()
        // Roam does not outlive the app that is holding it: the assertion and the activity token
        // are given back here, and the daemon drops the lease as this process's socket closes.
        roam.shutdown()
        // The host and every session it owns go with the app, and the wait for that is bounded.
        bridge.stop()
        spoolWatcher?.stop()
        sessionWatcher?.stop()
        outsideClicks.stop()
        timer?.invalidate()
    }

    @objc private func willSleep() {
        try? store.save(snapshot: engine.snapshot())
    }

    @objc private func didWake() {
        // Nothing to reset: elapsed time is not evidence here, so a sleep does not need forgiving.
        refresh()
    }

    @objc private func screensChanged() {
        // A display change can put the remembered corner somewhere that no longer exists.
        bubble.reposition(placement: config.bubblePlacement)
        panel.layoutAndPosition()
    }

    private func publishAppPresence() {
        let pid = ProcessInfo.processInfo.processIdentifier
        try? store.write(appStatus: AppRunStatus(
            pid: pid,
            pidStartedAt: ProcessProbe.snapshot(pid: pid)?.startedAt,
            version: AgentAttentionVersion.string,
            startedAt: Date()
        ))
    }

    // MARK: - The one cycle

    private func refresh() {
        reloadConfigIfChanged()

        // Prune first. Reading heartbeats before pruning would let a dead session be re-adopted
        // and re-pruned on alternate ticks forever.
        let orphans = store.pruneHeartbeats(
            now: Date(),
            staleAfter: config.staleSessionSeconds,
            liveness: SystemLiveness()
        )
        if !orphans.isEmpty {
            log("pruned \(orphans.count) orphaned session record(s)")
        }

        let drained = store.readSpool()
        if !drained.quarantined.isEmpty {
            log("quarantined unreadable spool files: \(drained.quarantined.joined(separator: ", "))")
        }

        var effects = engine.ingest(drained.events)
        effects += engine.applyHeartbeats(store.readHeartbeats())
        effects += engine.sweep()

        // Only delete the spool files once the state that absorbed them is on disk. A crash in
        // between replays them; the engine's recently-seen-id ring makes that a no-op.
        var saved = false
        do {
            try store.save(snapshot: engine.snapshot())
            saved = true
        } catch {
            log("could not save state, keeping \(drained.receipts.count) spool file(s) for replay: \(error)")
        }
        if saved {
            store.acknowledge(drained.receipts)
        }

        // Links for sessions that are gone are cleaned up here, and nowhere near the queue: a
        // retired link must never resolve, snooze or disturb a pending request.
        if let retired = try? pairings.retire(keeping: Set(engine.sessions.keys)), retired > 0 {
            log("retired \(retired) terminal link(s) for sessions that have ended")
        }

        announce(effects)
        render()

        // Deliberately nothing about roam here. The battery guard and the liveness stamp run off
        // the power lease's own 10-second heartbeat instead — see `RoamService.leaseRenewed()`:
        // this sweep's interval is user-editable up to an hour, which would leave a lid-closed
        // Mac unguarded for an hour at a time.

        // One handshake per tick, off this thread: it takes the script gate and waits on a
        // terminal, and neither belongs on the thread that draws the queue. A tick that finds
        // nothing to link does nothing at all.
        let identities = engine.sessions.values.map(\.identity)
        autoLinkQueue.async { [weak self] in
            guard let self else { return }
            if self.autoLinker.linkOne(among: identities) {
                DispatchQueue.main.async { self.render() }   // the row can say so straight away
            }
        }

        // Rate-limited internally, and entirely off this thread.
        discovery.scan()
        tabTitles.refresh()
        branches.refresh(
            sessions: engine.sessionsNeedingBranchRead(at: Date(), staleAfter: branches.staleAfter)
        )
    }

    /// Fold a completed registry scan into the queue. Main thread, called by `DiscoveryService`.
    private func applyDiscovery(_ report: DiscoveryReport) {
        lastDiscovery = report
        let added = engine.apply(discovery: report, at: Date())
        if added > 0 {
            log("discovered \(added) already-running session(s) from the registry "
                + "(\(report.verified.count) verified, \(report.rejected.count) rejected)")
        }
        if !report.inspectionAvailable {
            log("registry scan could not verify any process; nothing was added")
        }
        render()
        persist()
    }

    /// Speak and surface only what is *still* waiting once the whole cycle has run.
    private func announce(_ effects: [EngineEffect]) {
        let surviving = Set(engine.visibleItems().map(\.id))

        for effect in effects {
            switch effect {
            case .raised(let item):
                // Rechecked here, at dispatch, against the session's **current** episode — not
                // against what was true when the signal arrived. A generic completion that the
                // session has already worked past is dropped; a genuine ask is not, because a
                // background job making progress does not answer a question put to a person.
                let dispatchable = AlertDispatch.shouldDispatch(
                    item, session: engine.sessions[item.sessionID], at: Date())
                let stillWaiting = surviving.contains(item.id) && dispatchable
                // The chime is told about the resolved case too, and refuses it there. A sound for
                // something that is no longer waiting is a sound you get up for and find nothing.
                let sounded = chime.consider(item, surviving: stillWaiting, at: Date())
                guard stillWaiting else {
                    log("dropped \(item.kind.rawValue) for \(item.identity.projectName) before showing it (resolved in the same pass)")
                    continue
                }
                // The badge changes; the panel does not open. An ask arriving is a signal, and a
                // window appearing over what somebody is reading is not the same thing — a session
                // in another worktree finishing a turn used to throw this list across the screen.
                presentation.attentionRaised()
                speech.announce(item)
                if sounded { log("chimed for \(item.identity.projectName)") }
                log("raised \(item.kind.rawValue) for \(item.identity.projectName) [\(item.source.rawValue)]")

            case .unsnoozed(let item):
                guard surviving.contains(item.id) else { continue }
                presentation.snoozeExpired()
                log("snooze expired for \(item.identity.projectName)")

            case .sessionDropped(let sessionID, let reason):
                store.removeHeartbeat(sessionID: sessionID)
                log("dropped session \(String(sessionID.prefix(8))) (\(reason.rawValue))")

            case .repeated, .resolved:
                break
            }
        }
    }

    private func render() {
        let now = Date()
        let items = engine.visibleItems(at: now)
        let sessions = engine.sessions.values.sorted { $0.identity.projectName < $1.identity.projectName }

        // Once the queue empties, collapse back to just the bubble — unless the user opened the
        // panel themselves, in which case it is theirs to close.
        if items.isEmpty { presentation.queueEmptied() }

        bubble.update(pendingCount: items.count, unseenCount: engine.unseenCount,
                      expanded: isExpanded, roaming: roam.isActive)
        if config.bubbleEnabled { bubble.show() } else { bubble.hide() }

        panel.settings = config
        if isExpanded {
            panel.render(
                items: items,
                sessions: sessions,
                snoozedCount: engine.snoozedCount,
                maxVisible: config.maxVisibleCards,
                now: now,
                anchor: config.bubbleEnabled ? bubble.frame : nil,
                backgroundEvidenceTTL: config.backgroundEvidenceTTLSeconds
            )
            panel.show()
        } else {
            panel.hide()
        }

        updateStatusItem(items: items)
    }

    private func persist() {
        do {
            try store.save(snapshot: engine.snapshot())
        } catch {
            log("could not save state: \(error)")
        }
    }

    // MARK: - Bubble

    private func wireBubble() {
        bubble.onToggle = { [weak self] in self?.toggleExpansion() }
        bubble.contextMenuProvider = { [weak self] in self?.buildBubbleMenu() }
        bubble.onPlacementChanged = { [weak self] placement in
            guard let self else { return }
            self.config.bubblePlacement = placement
            self.applyConfigChange()
            self.log("bubble moved to \(placement.corner.rawValue) +\(Int(placement.offsetX))/\(Int(placement.offsetY))")
        }
    }

    /// The one way in: a click on the bubble, or the menu item that says so.
    private func toggleExpansion() {
        let wasExpanded = isExpanded
        presentation.userToggled()
        // Marked on the way **out**, not on the way in. Marking them as the panel opens would clear
        // every row's "new" dot in the same instant the panel appeared to show it — the indicator
        // would be correct and useless. Closing the panel is the honest moment: they were in front
        // of you, and you are done looking. Seeing is still not deciding — nothing is dismissed,
        // resolved or snoozed, and the queue is exactly as long afterwards.
        if wasExpanded, !isExpanded, engine.markVisibleAsSeen(at: Date()) > 0 {
            try? store.save(snapshot: engine.snapshot())   // so a restart does not make them new again
        }
        // A list somebody is opening is worth one script, however recent the last reading was: the
        // whole point of the number and the name is to be right at the moment you look at them.
        if !wasExpanded { tabTitles.refresh(force: true) }
        render()
    }

    /// Clicking away closes the panel. It is a *view* being put away, not a decision about anything
    /// in it: nothing is dismissed, snoozed or resolved, the badge is unchanged, and one click on
    /// the bubble brings it straight back.
    private func wireOutsideClicks() {
        outsideClicks.onOutsideClick = { [weak self] in
            guard let self, self.outsideClicks.shouldCollapse(panelIsExpanded: self.isExpanded, at: Date()) else { return }
            self.collapseForPresentation()
        }
        outsideClicks.start()
    }

    private func collapseForPresentation() {
        // A click elsewhere puts the view away. Nothing in the queue is decided by it, and nothing
        // will bring it back except the user asking again.
        let wasExpanded = isExpanded
        presentation.clickedAway()
        // Clicking away is still having looked: the rows were on screen. Same rule as the bubble,
        // so a queue does not stay marked new because of *how* the panel was closed.
        if wasExpanded, !isExpanded, engine.markVisibleAsSeen(at: Date()) > 0 {
            try? store.save(snapshot: engine.snapshot())
        }
        render()
    }

    // MARK: - Panel actions

    private func wirePanelCallbacks() {
        panel.onActivate = { [weak self] item in self?.open(item.identity, clearing: item.id) }
        panel.onOpenSession = { [weak self] session in self?.open(session.identity, clearing: nil) }
        panel.onCollapse = { [weak self] in
            guard let self else { return }
            self.presentation.clickedAway()
            self.render()
        }
        panel.onSnooze = { [weak self] item in
            guard let self else { return }
            self.engine.snooze(itemID: item.id)
            self.render()
            self.persist()
        }
        panel.onDismiss = { [weak self] item in
            guard let self else { return }
            _ = self.engine.dismiss(itemID: item.id)
            self.render()
            self.persist()
        }
        panel.onDismissAll = { [weak self] in
            guard let self else { return }
            _ = self.engine.dismissAll()
            self.render()
            self.persist()
        }
        // One setting at a time, applied to the live config, written whole, and reported honestly.
        // The panel is told whether the write happened so it can never show a preference that is
        // not on disk.
        panel.onSettingChange = { [weak self] change in
            guard let self else { return false }
            switch change {
            case .soundEnabled(let on): self.config.soundEnabled = on
            case .speechEnabled(let on): self.config.speechEnabled = on
            case .chimeEnabled(let on): self.config.chimeEnabled = on
            case .notifyOnWorkComplete(let on): self.config.notifyOnWorkComplete = on
            case .notifyOnIdle(let on): self.config.notifyOnIdle = on
            case .includeHookMessages(let on): self.config.includeHookMessages = on
            case .bubbleEnabled(let on): self.config.bubbleEnabled = on
            case .snoozeDurationSeconds(let seconds): self.config.snoozeDurationSeconds = seconds
            }
            return self.applyConfigChange()
        }
        // An explicit request to hear it, once. Refused while muted — the master switch means what
        // it says — and it never writes a preference: previewing is not choosing.
        panel.onPreviewChime = { [weak self] in
            guard let self, self.config.soundEnabled else { return }
            self.chime.preview()
        }
        // The contract window edits exactly one line of the configuration, through the same write
        // path as every other setting, and is told honestly whether the write landed.
        // Nothing is changed in memory until the write has succeeded. Setting the field first and
        // reporting the failure afterwards left the rejected selection live, where the next
        // unrelated settings save would write it out as though it had been accepted.
        contractWindow.onSelect = { [weak self] path in
            guard let self else { return false }
            switch ContractSelection.store(path, current: self.config, to: self.paths.configFile) {
            case .failed:
                return false                       // the configuration here is untouched
            case .saved(let updated):
                self.config = updated
                self.configModifiedAt = self.fileModificationDate(self.paths.configFile)
                self.applyRuntimeConfig()          // no second write: the file is already current
                self.render()
                return true
            }
        }
        panel.onShowContract = { [weak self] in
            guard let self else { return }
            self.contractWindow.show(selection: self.config.orchestrationContractPath)
        }
        panel.onNeedsRedraw = { [weak self] in self?.render() }
        // Reading a conversation is an explicit request, answered off the main thread, and shown in
        // its own window. Nothing about it touches the queue.
        // Details describes the link, and opens the pairing window on request. The link itself is
        // never made or changed without the user confirming it in that window.
        panel.pairingLookup = { [weak self] sessionID in self?.pairings.pairing(for: sessionID) }
        panel.onLinkTerminal = { [weak self] identity in
            self?.presentPairingWindow(for: identity)
        }
        panel.onShowContext = { [weak self] identity in
            guard let self else { return }
            let item = self.engine.session(identity.sessionID)?.currentItemID.flatMap { self.engine.item(id: $0) }
            self.contextWindow.show(identity: identity, attention: item)
        }
        panel.onCopyResume = { [weak self] identity in
            guard let self else { return }
            self.copyToPasteboard(TerminalTarget.identifyingHelp(for: identity).joined(separator: "\n"))
            self.panel.flash("Details for \(identity.projectName) copied — project, session id and resume command")
        }
        wireContextWindow()
    }

    /// The one place the pairing window is presented from.
    ///
    /// Both the panel's ⋯ menu and the conversation window come through here, so there is a single
    /// persistence path and a single validation path. A second copy of this wiring is how one
    /// surface ends up saving a link the other would have refused.
    private func presentPairingWindow(for identity: SessionIdentity) {
        // The window is told whether the write actually happened, so it can never say "linked"
        // about something that is not on disk.
        pairingWindow.onConfirm = { [weak self] pairing in
            guard let self else { return false }
            do {
                try self.pairings.put(pairing)
            } catch {
                self.log("could not save the terminal link for \(String(pairing.sessionID.prefix(8))): \(error)")
                return false
            }
            self.log("linked session \(String(pairing.sessionID.prefix(8))) to Ghostty terminal \(pairing.terminalID)")
            self.render()
            // If the conversation window is open on this session, its Open session action becomes
            // usable now — without disturbing what is on screen.
            self.contextWindow.refreshOpenAction()
            return true
        }
        pairingWindow.onUnlink = { [weak self] sessionID in
            guard let self else { return false }
            do {
                try self.pairings.remove(sessionID: sessionID)
            } catch {
                self.log("could not remove the terminal link for \(String(sessionID.prefix(8))): \(error)")
                return false
            }
            self.log("unlinked session \(String(sessionID.prefix(8)))")
            self.render()
            self.contextWindow.refreshOpenAction()
            return true
        }
        // The engine's own record, read at the moment of saving rather than at the moment the
        // window opened. Automation can take seconds, and a session can be replaced in that time
        // under the same id.
        pairingWindow.currentIdentity = { [weak self] sessionID in
            self?.engine.session(sessionID)?.identity
        }
        pairingWindow.show(identity: identity, existing: pairings.pairing(for: identity.sessionID))
    }

    /// **Open session**, from the conversation window.
    ///
    /// Three rules make this different from clicking a row: the session is resolved from the engine
    /// *at the click*, not from whatever identity the window opened with; the queue is never
    /// touched, whatever the outcome; and there is no consolation prize — no app-only raise, no
    /// clipboard, no resume command. Either the linked tab is reached and verified, or the window
    /// says what stopped it and offers the one thing that can fix it.
    private func wireContextWindow() {
        contextWindow.linkStatus = { [weak self] sessionID in
            self?.pairings.pairing(for: sessionID) != nil
        }
        contextWindow.onLinkTerminal = { [weak self] sessionID in
            guard let self, let identity = self.engine.session(sessionID)?.identity else { return }
            self.presentPairingWindow(for: identity)
        }
        contextWindow.onOpenSession = { [weak self] sessionID, report in
            guard let self else { return }
            // Resolved now. A session that has ended, or been replaced under the same id, is not the
            // session whose conversation is on screen.
            guard let identity = self.engine.session(sessionID)?.identity else {
                report(.failed("Agent Warden is no longer tracking this session, so there is nothing "
                               + "to open. The conversation above is history.", offerRelink: false))
                return
            }
            guard let pairing = self.pairings.pairing(for: sessionID) else {
                self.presentPairingWindow(for: identity)
                report(.needsLink("No Ghostty tab is linked to this session yet. Pick it in the "
                                  + "linking window, then press Open session again."))
                return
            }

            self.log("open from conversation \(identity.projectName)")
            TerminalActivator.activate(identity, pairing: pairing) { [weak self] outcome in
                guard let self else { return }
                self.log("open from conversation \(identity.projectName): \(outcome.level.rawValue) — \(outcome.message)")
                switch outcome.level {
                case .exactTab:
                    // Nothing is dismissed or snoozed. Arriving at a tab is not the same as having
                    // dealt with what the session asked for, and this window never decides that.
                    report(.landed(outcome.message))
                case .appOnly, .failed:
                    report(.failed(outcome.message, offerRelink: true))
                }
            }
        }
    }

    /// Try to take the user to a session.
    ///
    /// The item is only cleared when we actually landed on its tab. Bringing an application to the
    /// front is not evidence that the right tab was found, let alone that the ask was dealt with,
    /// so an app-only jump leaves the card exactly where it was.
    private func open(_ identity: SessionIdentity, clearing itemID: String?) {
        // Read, now. Clicking a row is unambiguous evidence that it was in front of the user, so the
        // dot goes out on the click rather than on the outcome. Whether Ghostty could be reached,
        // and whether the right tab was found, are separate questions asked below — and a row that
        // still shows as unread after you clicked it is simply wrong, however that jump ended.
        if let itemID, engine.markSeen(itemID: itemID, at: Date()) {
            persist()
            render()
        }

        let pairing = pairings.pairing(for: identity.sessionID)
        let plan = TerminalTarget.plan(for: identity, pairing: pairing)
        guard plan.confidence != .none else {
            copyToPasteboard(TerminalTarget.identifyingHelp(for: identity).joined(separator: "\n"))
            panel.flash("No terminal recorded for \(identity.projectName) — details copied instead.", seconds: 12)
            return
        }

        panel.flash("Opening \(identity.terminalName) for \(identity.projectName)…", seconds: 20)
        TerminalActivator.activate(identity, pairing: pairing) { [weak self] outcome in
            guard let self else { return }
            self.log("open \(identity.projectName): \(outcome.level.rawValue) — \(outcome.message)")

            switch outcome.level {
            case .exactTab:
                // Demoted, not dismissed. You are now looking at the session, so this row drops
                // below everything you have not been to — but opening a tab is how you find out it
                // still needs you, so it stays in the queue until it is answered or dismissed.
                if let itemID { _ = self.engine.markVisited(itemID: itemID, at: Date()) }
                self.panel.flash(outcome.message)
            case .appOnly:
                // Say which tab to look for. We cannot select it, so identifying it is the help.
                var hint = "\(identity.terminalName) is forward — find \(identity.projectName)"
                if let tty = identity.tty, !tty.isEmpty { hint += " on \(tty)" }
                hint += " (session \(identity.shortSessionID)). Still listed until you dismiss it."
                self.panel.flash(hint, seconds: 14)
            case .failed:
                // The refusal message promises the details; make that true. Nothing is opened and
                // the item stays pending.
                self.copyToPasteboard(TerminalTarget.identifyingHelp(for: identity).joined(separator: "\n"))
                self.panel.flash(outcome.message, seconds: 14)
            }
            self.render()
            self.persist()
        }
    }

    /// A bridge caller asking for a session's tab. Exact tab or nothing: bringing Ghostty forward
    /// without the right tab is not what was asked for, so it is reported as a failure — and, unlike
    /// a click, it touches neither the queue nor the pasteboard.
    private func focusForBridge(_ sessionID: String, reply: @escaping (BridgeResponse) -> Void) {
        guard let identity = engine.session(sessionID)?.identity else {
            reply(BridgeResponse(ok: false, error: BridgeError(
                code: .notOwned, message: "Agent Warden is not tracking session \(sessionID).")))
            return
        }
        guard let pairing = pairings.pairing(for: sessionID) else {
            reply(BridgeResponse(ok: false, error: BridgeError(
                code: .malformed, message: "No Ghostty tab is linked to \(identity.projectName). "
                    + "Link it from the panel's ⋯ menu first; nothing was focused.")))
            return
        }
        TerminalActivator.activate(identity, pairing: pairing) { [weak self] outcome in
            self?.log("focus from the bridge \(identity.projectName): \(outcome.level.rawValue) — \(outcome.message)")
            switch outcome.level {
            case .exactTab:
                reply(BridgeResponse(ok: true))
            case .appOnly, .failed:
                reply(BridgeResponse(ok: false, error: BridgeError(code: .clientUnavailable,
                                                                   message: outcome.message)))
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Roam

    /// What the roam menu item should say right now, computed fresh for every render so the
    /// bubble menu and the menu-bar menu — which both call `BubbleMenu.roamItem` with this
    /// same value — cannot disagree.
    ///
    /// This only gathers the three facts and hands them to `RoamMenuText.state`, which is
    /// where the actual mapping (and its priority order) lives, so that logic is unit tested
    /// in Core rather than only exercised indirectly through this property. `helperPresent` is
    /// answered proactively here, by checking whether the daemon's socket file exists — a
    /// `stat`, not a `connect`, so it costs nothing and touches nothing the daemon owns.
    /// `foreignHold` cannot be answered proactively (see `roamForeignHold`) and so only reflects
    /// an attempt that has actually reported one.
    private var roamMenuState: RoamMenuState {
        RoamMenuText.state(
            isActive: roam.isActive,
            helperPresent: FileManager.default.fileExists(atPath: PowerLeaseClient.socketPath),
            foreignHold: roamForeignHold
        )
    }

    /// The default IPv4 gateway, read from the System Configuration dynamic store — the same
    /// place `scutil` reads it from (`scutil <<< 'show State:/Network/Global/IPv4'` on this
    /// machine returns a `Router` key holding exactly this address). This is an in-process
    /// query of `configd`'s store, not a fork/exec of `route` or `netstat`, and it needs no
    /// permission prompt. Feeds `RoamNetwork.classify(gateway:)`, which wants only the
    /// address and never the interface name.
    private func currentGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "dev.agentwarden.roam" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any]
        else { return nil }
        return global["Router"] as? String
    }

    /// The single action behind the roam item in both menus.
    ///
    /// **Policy is consulted here, not inside `RoamService`.** `RoamPolicy.entryAction` is
    /// what stops "roam granted at 8% battery, then slept ten seconds later by the guard's
    /// first heartbeat" from reading as a malfunction — refusing before the daemon is ever
    /// asked, with the reading that caused it, is the honest answer. `RoamService` holds no
    /// battery policy of its own and this keeps it that way.
    @objc private func toggleRoam() {
        if roam.isActive {
            roam.exit()
            return
        }
        // The menu item is disabled while `isChanging` (see `RoamMenuText.isEnabled`), so this
        // only guards a route that does not go through a click — `NSApp.sendAction`, called
        // directly, as `UICheck` does.
        guard !roam.isChanging else { return }

        let reading = PowerProbe.read()
        switch RoamPolicy.entryAction(reading: reading, threshold: config.roamBatteryThreshold) {
        case .refuse(let percent):
            // Through `recordExternalNotice`, not a bare `flash`: a click that is refused and
            // says nothing anywhere the user can find later is the "nothing happens when I
            // click it" failure `RoamMenuText` warns against. This reaches the panel's status
            // line *and* `lastNotice`, so it also survives on the menu's notice row if the
            // panel happened to be closed at the moment of the click — which is the common case,
            // since only the user opens it.
            roam.recordExternalNotice(
                "Roam refused: battery at \(percent)%, at or below the "
                + "\(config.roamBatteryThreshold)% guard threshold. Charge first, or lower the "
                + "threshold in config.json.",
                logPrefix: "roam entry refused: "
            )
            render()
            return
        case .proceed:
            break
        }

        // Hotspot awareness is gateway-only, deliberately. The brief's original sketch also
        // compared the *current* network's name against `config.roamHotspotSSID` to warn "you
        // are on the wrong network" — reading a live SSID needs Location authorisation on
        // modern macOS, and asking a menu-bar app's user to grant that for a warning the
        // gateway check already substantially covers was judged not worth it. That is an
        // owner decision, not an engineering one, which is why `roamHotspotSSID` was removed
        // from `AttentionConfig` rather than merely left unused — see `Config.swift`. `kind`
        // below is real; `ssid` stays nil because there is no reader for it, not because this
        // call site forgot to pass one.
        let hotspot = RoamHotspot(kind: RoamNetwork.classify(gateway: currentGateway()).rawValue)
        roam.enter(hotspot: hotspot, onBattery: !reading.onAC) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .entered:
                self.roamForeignHold = false
            case .alreadyOn:
                break
            case .busyChanging:
                // Rare: something else on this same `RoamService` was already mid-flight the
                // instant this fired, which the disabled menu item is meant to prevent from a
                // click. Nothing was asked of the daemon, so nothing needs undoing, and this is
                // not persisted to `lastNotice` — there is nothing wrong to remember, only a
                // click that arrived a moment early.
                self.panel.flash("Roam is already changing — try again in a moment.", seconds: 8)
            case .refused(let error):
                self.roamForeignHold = (error == .foreign)
                // Same reasoning as the entry refusal above: this is new code in the same
                // diff as the notice row, so it goes through the same one door.
                self.roam.recordExternalNotice("Roam could not start: \(error.rawValue)",
                                               logPrefix: "roam enter refused: ")
            }
            self.render()
        }
    }

    // MARK: - Menu bar (secondary surface)

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        // The count sits to the right of the shield, the same way the bubble draws its badge.
        item.button?.imagePosition = .imageLeading
        statusItem = item
        updateStatusItem(items: [])
    }

    private func updateStatusItem(items: [AttentionItem]) {
        guard let statusItem else { return }
        let count = items.count
        // **The bubble's own glyph, for the same reason it is a shield there.** These are two
        // surfaces of one app, and a bullet in the menu bar next to a shield on the desktop gave
        // a person nothing to recognise it by — which is exactly how it was missed.
        // `shield.lefthalf.filled` when something waits, matching `BubbleView.update`, so the two
        // never disagree about whether anything needs you.
        //
        // Template rendering is not decoration: the menu bar changes colour with the wallpaper and
        // the system appearance, and only a template image is tinted to follow it. A literal text
        // bullet could not.
        let symbol = count > 0 ? "shield.lefthalf.filled" : "shield"
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: "Agent Warden")
            ?? NSImage(systemSymbolName: "shield", accessibilityDescription: "Agent Warden")
        glyph?.isTemplate = true
        statusItem.button?.image = glyph
        // The old text is kept as the fallback rather than deleted: if neither symbol resolves,
        // an item with no image and no title is an invisible menu bar item, and the one thing this
        // surface must never be is absent.
        statusItem.button?.title = glyph == nil
            ? (count == 0 ? "◦" : "● \(count)")
            : (count == 0 ? "" : " \(count)")
        statusItem.button?.setAccessibilityLabel(
            count == 0 ? "Agent Warden, nothing waiting" : "Agent Warden, \(count) waiting")
        statusItem.button?.toolTip = count == 0
            ? "Agent Warden — nothing waiting"
            : items.map { "\($0.kind.glyph) \($0.identity.projectName): \($0.reasonLine)" }.joined(separator: "\n")
        statusItem.menu = buildMenu(items: items)
    }

    private func buildMenu(items: [AttentionItem]) -> NSMenu {
        let menu = NSMenu()
        let sessionCount = engine.sessions.count

        let header = NSMenuItem(
            title: items.isEmpty
                ? "Nothing waiting · \(sessionCount) session\(sessionCount == 1 ? "" : "s") tracked"
                : "\(items.count) waiting · \(sessionCount) session\(sessionCount == 1 ? "" : "s") tracked",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        // Paused on its own work is deliberately below the fold and never in the badge: nothing is
        // being asked of you, so it must not read as an alert.
        let background = engine.sessionsWaitingOnBackgroundWork(at: Date())
        if !background.isEmpty {
            let entry = NSMenuItem(
                title: "\(background.count) waiting on background work",
                action: nil, keyEquivalent: ""
            )
            entry.isEnabled = false
            entry.toolTip = background
                .map { "\($0.identity.displayName) — \($0.background?.summaryLine ?? "paused")" }
                .joined(separator: "\n")
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        for item in items {
            let entry = NSMenuItem(title: "\(item.kind.glyph) \(item.identity.projectName) — \(item.reasonLine)",
                                   action: #selector(menuActivate(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            menu.addItem(entry)
        }

        let snoozed = engine.snoozedCount
        if snoozed > 0 {
            let entry = NSMenuItem(title: "\(snoozed) snoozed", action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }

        if !items.isEmpty {
            menu.addItem(.separator())
            let dismissAll = NSMenuItem(title: "Dismiss all", action: #selector(menuDismissAll), keyEquivalent: "")
            dismissAll.target = self
            menu.addItem(dismissAll)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: isExpanded ? "Collapse session list" : "Show session list",
                                action: #selector(menuToggleExpansion), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let showBubble = NSMenuItem(title: "Floating bubble", action: #selector(menuToggleBubble), keyEquivalent: "")
        showBubble.target = self
        showBubble.state = config.bubbleEnabled ? .on : .off
        menu.addItem(showBubble)

        // Same constructor, same inputs, as the bubble's own menu builds in `buildBubbleMenu`
        // — see `BubbleMenu.roamItem`'s doc for why that must hold.
        menu.addItem(BubbleMenu.roamItem(state: roamMenuState, isChanging: roam.isChanging,
                                        target: self, action: #selector(toggleRoam)))
        if let noticeItem = BubbleMenu.roamNoticeItem(notice: roam.lastNotice) {
            menu.addItem(noticeItem)
        }

        // Keyboard- and menu-driven placement, so moving the bubble never requires a drag.
        menu.addItem(placementMenuItem())

        menu.addItem(.separator())

        let speak = NSMenuItem(title: "Speak alerts (local)", action: #selector(menuToggleSpeech), keyEquivalent: "")
        speak.target = self
        speak.state = config.speechEnabled ? .on : .off
        menu.addItem(speak)

        let chimeItem = NSMenuItem(title: "Attention chime", action: #selector(menuToggleChime), keyEquivalent: "")
        chimeItem.target = self
        chimeItem.state = config.chimeEnabled ? .on : .off
        menu.addItem(chimeItem)

        let complete = NSMenuItem(title: "Alert when work completes", action: #selector(menuToggleWorkComplete), keyEquivalent: "")
        complete.target = self
        complete.state = config.notifyOnWorkComplete ? .on : .off
        menu.addItem(complete)

        let messages = NSMenuItem(title: "Keep hook message text", action: #selector(menuToggleMessages), keyEquivalent: "")
        messages.target = self
        messages.state = config.includeHookMessages ? .on : .off
        menu.addItem(messages)

        menu.addItem(.separator())

        let reveal = NSMenuItem(title: "Reveal data folder", action: #selector(menuReveal), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let diagnostics = NSMenuItem(title: "Copy diagnostics", action: #selector(menuDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

        menu.addItem(.separator())
        menu.addItem(BubbleMenu.quitItem(target: self, action: #selector(menuQuit)))

        return menu
    }

    /// Keyboard- and menu-driven placement, so moving the bubble never requires a drag. Shared by
    /// the menu bar item and the bubble's own menu.
    private func placementMenuItem() -> NSMenuItem {
        let placement = NSMenuItem(title: "Bubble position", action: nil, keyEquivalent: "")
        let placementMenu = NSMenu()
        for corner in ScreenCorner.allCases {
            let entry = NSMenuItem(title: corner.label, action: #selector(menuSetCorner(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = corner.rawValue
            entry.state = config.bubblePlacement.corner == corner ? .on : .off
            placementMenu.addItem(entry)
        }
        placementMenu.addItem(.separator())
        for (title, dx, dy) in [("Nudge in", -12.0, 0.0), ("Nudge out", 12.0, 0.0),
                                ("Nudge towards corner", 0.0, -12.0), ("Nudge away from corner", 0.0, 12.0)] {
            let entry = NSMenuItem(title: title, action: #selector(menuNudge(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [dx, dy]
            placementMenu.addItem(entry)
        }
        placementMenu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset position", action: #selector(menuResetPlacement), keyEquivalent: "")
        reset.target = self
        placementMenu.addItem(reset)
        placement.submenu = placementMenu
        return placement
    }

    /// The bubble's own right-click / control-click menu. Built by `BubbleMenu`, which owns the
    /// single Quit and roam constructors the menu bar item uses too.
    func buildBubbleMenu() -> NSMenu {
        BubbleMenu.build(
            pendingCount: engine.pendingCount,
            isExpanded: isExpanded,
            target: self,
            actions: .init(
                toggleSessions: #selector(menuToggleExpansion),
                revealDataFolder: #selector(menuReveal),
                quit: #selector(menuQuit),
                toggleRoam: #selector(toggleRoam),
                placement: placementMenuItem()
            ),
            roamState: roamMenuState,
            roamIsChanging: roam.isChanging,
            roamNotice: roam.lastNotice
        )
    }

    @objc private func menuActivate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let item = engine.item(id: id) else { return }
        open(item.identity, clearing: item.id)
    }

    @objc private func menuDismissAll() {
        _ = engine.dismissAll()
        render()
        persist()
    }

    @objc private func menuToggleExpansion() {
        toggleExpansion()
    }

    @objc private func menuToggleBubble() {
        config.bubbleEnabled.toggle()
        applyConfigChange()
    }

    @objc private func menuSetCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let corner = ScreenCorner(rawValue: raw) else { return }
        config.bubblePlacement.corner = corner
        applyConfigChange()
    }

    @objc private func menuNudge(_ sender: NSMenuItem) {
        guard let deltas = sender.representedObject as? [Double], deltas.count == 2 else { return }
        config.bubblePlacement = BubbleGeometry.nudged(config.bubblePlacement, dx: deltas[0], dy: deltas[1])
        _ = applyConfigChange()
    }

    @objc private func menuResetPlacement() {
        config.bubblePlacement = .default
        _ = applyConfigChange()
    }

    @objc private func menuToggleSpeech() {
        config.speechEnabled.toggle()
        _ = applyConfigChange()
    }

    @objc private func menuToggleChime() {
        config.chimeEnabled.toggle()
        _ = applyConfigChange()
    }

    @objc private func menuToggleWorkComplete() {
        config.notifyOnWorkComplete.toggle()
        _ = applyConfigChange()
    }

    @objc private func menuToggleMessages() {
        config.includeHookMessages.toggle()
        _ = applyConfigChange()
    }

    /// Applies the current config everywhere and writes it, reporting whether the write succeeded.
    ///
    /// The whole struct is written from a loaded copy, so a field this change never touched keeps
    /// its value — a hand-edited setting is not lost because a toggle was flipped. Audio is applied
    /// before the write, so a mute takes effect immediately and does not wait on the disk.
    /// Everything a configuration change means to the running app, and **nothing that writes**.
    ///
    /// Split out so a change that was already saved elsewhere can be applied without writing the
    /// file a second time.
    private func applyRuntimeConfig() {
        engine.updateConfig(config)
        // Mute is a master switch: speech stops now, and a queued utterance is cut off rather than
        // finished. Nothing that happened while muted is replayed when sound comes back.
        speech.isEnabled = config.speechIsAudible
        speech.voiceIdentifier = config.speechVoiceIdentifier
        if !config.speechIsAudible { speech.stop() }
        chime.isEnabled = config.chimeIsAudible
        if !config.chimeIsAudible { chime.stop() }
        bubble.apply(placement: config.bubblePlacement, size: CGFloat(config.bubbleSize))
    }

    @discardableResult
    private func applyConfigChange() -> Bool {
        config = config.validated()
        applyRuntimeConfig()

        var saved = true
        do {
            try config.save(to: paths.configFile)
        } catch {
            saved = false
            log("could not save config: \(error.localizedDescription)")
        }
        configModifiedAt = fileModificationDate(paths.configFile)
        render()
        return saved
    }

    @objc private func menuReveal() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: paths.root.path)
    }

    @objc private func menuDiagnostics() {
        let report = StatusReport.build(store: store, config: config, discovery: lastDiscovery,
                                        pairings: pairings.load())
        copyToPasteboard(report.textSummary() + "\n\n" + report.jsonString())
        panel.flash("Diagnostics copied to the clipboard")
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Small helpers

    private func reloadConfigIfChanged() {
        let modified = fileModificationDate(paths.configFile)
        guard modified != configModifiedAt else { return }
        configModifiedAt = modified
        let previousPlacement = config.bubblePlacement
        let previousSize = config.bubbleSize
        config = AttentionConfig.load(from: paths.configFile)
        engine.updateConfig(config)
        // A hand-edited file gets the same master-switch treatment as a click on the control.
        speech.isEnabled = config.speechIsAudible
        speech.voiceIdentifier = config.speechVoiceIdentifier
        if !config.speechIsAudible { speech.stop() }
        chime.isEnabled = config.chimeIsAudible
        if !config.chimeIsAudible { chime.stop() }
        if config.bubblePlacement != previousPlacement || config.bubbleSize != previousSize {
            bubble.apply(placement: config.bubblePlacement, size: CGFloat(config.bubbleSize))
        }
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func log(_ message: String) {
        let line = "\(JSONCoding.dateFormatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = paths.logFile
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            trimLogIfLarge(url)
        } else {
            try? AtomicFile.write(data, to: url)
        }
    }

    /// Keep the log small; it is a debugging aid, not an archive.
    private func trimLogIfLarge(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue > 512 * 1024,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let tail = contents.suffix(128 * 1024)
        try? AtomicFile.write(Data(tail.utf8), to: url)
    }
}
