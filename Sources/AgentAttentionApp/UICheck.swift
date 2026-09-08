import AppKit
import AgentAttentionCore

/// Builds the real bubble, panel and menu-bar item with synthetic data, checks what can be checked
/// without a human, then exits.
///
/// Not a substitute for looking at the screen. It does verify the parts a screenshot would not
/// prove anyway: that the views construct, that the bubble lands where it was told to and stays on
/// screen, that the panel anchors to it, that a long session name is shown in full rather than cut
/// off, that the badge and empty state say the right thing, that the buttons are wired to the right
/// items, that every click target carries the cursor policy, and that everything has an
/// accessibility label.
///
/// `--uicheck --png <path>` also writes the rendered panel to a PNG. That draws this app's own view
/// into a bitmap; it does not capture the screen and cannot see any other application.
enum UICheck {
    static func run(pngPath: String? = nil, readabilityPath: String? = nil) -> Int32 {
        var failures: [String] = []
        func check(_ description: String, _ condition: Bool) {
            print("  \(condition ? "✔" : "✘") \(description)")
            if !condition { failures.append(description) }
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            print("no screen available — cannot run the UI check")
            return 1
        }
        let visible = screen.visibleFrame
        let now = Date()
        let items = sampleItems()
        // Two of the open requests belong to sessions that are also in the list. That is the case
        // the old layout drew twice — once as a card, once as a row — and the case the single list
        // has to collapse into one row each.
        let sessions = sampleSessions() + [
            SessionState(identity: items[0].identity, activity: .awaitingUser,
                         lastEventAt: Date(), lastActivityAt: Date(), currentItemID: items[0].id),
            SessionState(identity: items[1].identity, activity: .awaitingUser,
                         lastEventAt: Date(), lastActivityAt: Date(), currentItemID: items[1].id),
        ]

        // MARK: Bubble

        print("Bubble")
        let bubble = BubbleController(size: 56)
        var toggles = 0
        var lastPlacement: BubblePlacement?
        bubble.onToggle = { toggles += 1 }
        bubble.onPlacementChanged = { lastPlacement = $0 }

        bubble.apply(placement: .default, size: 56)
        bubble.show()
        bubble.update(pendingCount: 0, expanded: false)

        check("the bubble is visible with nothing pending", bubble.isVisible)
        check("the bubble is 56pt across", abs(bubble.frame.width - 56) < 1 && abs(bubble.frame.height - 56) < 1)
        check("the bubble sits inside the visible screen area", visible.contains(bubble.frame))
        check("the default placement is bottom right", abs(bubble.frame.maxX - (visible.maxX - 24)) < 1)
        check("the default placement clears the very corner",
              bubble.frame.minY > visible.minY + 60)
        check("no badge when nothing is pending", bubble.badgeIsHidden)
        check("the empty bubble claims only what it knows", bubble.accessibilityLabel.contains("No confirmed requests"))

        bubble.update(pendingCount: 3, expanded: false)
        check("the badge appears when something is pending", !bubble.badgeIsHidden)
        check("the bubble announces the count", bubble.accessibilityLabel.contains("3 sessions waiting"))

        bubble.debugPress()
        bubble.debugPress()
        check("pressing the bubble asks to toggle the panel", toggles == 2)
        check("the glyph and badge do not steal the click from the bubble",
              bubble.debugHitTestCentreIsWholeBubble && bubble.debugHitTestOverBadgeIsWholeBubble)
        check("the bubble tracks the cursor even when the window is not key",
              bubble.debugTrackingCoversCursor)

        print("  frame: \(Int(bubble.frame.minX)),\(Int(bubble.frame.minY)) in visible \(Int(visible.width))×\(Int(visible.height))")

        // MARK: Bubble context menu

        print("Bubble menu")
        let quitTarget = QuitProbe()
        bubble.contextMenuProvider = {
            BubbleMenu.build(
                pendingCount: 3, isExpanded: false, target: quitTarget,
                actions: .init(toggleSessions: #selector(QuitProbe.menuToggleExpansion),
                               revealDataFolder: #selector(QuitProbe.menuReveal),
                               quit: #selector(QuitProbe.menuQuit),
                               placement: NSMenuItem(title: "Bubble position", action: nil, keyEquivalent: ""))
            )
        }

        let togglesBefore = toggles
        var dragsSeen = 0
        bubble.onDragBegan = { dragsSeen += 1 }

        check("a right-click routes to the menu, not to a click or a drag",
              bubble.debugRoute(button: 1) == .openMenu)
        check("control-left-click does the same, as it has on macOS forever",
              bubble.debugRoute(button: 0, modifiers: [.control]) == .openMenu)
        check("a plain left-click still starts a click or a drag",
              bubble.debugRoute(button: 0) == .beginClickOrDrag)
        check("a shift- or command-click is still an ordinary click",
              bubble.debugRoute(button: 0, modifiers: [.shift]) == .beginClickOrDrag
              && bubble.debugRoute(button: 0, modifiers: [.command]) == .beginClickOrDrag)

        let rightMenu = bubble.debugPressSequence(button: 1)
        check("right-click produces a menu", rightMenu != nil)
        check("and it does not also toggle the panel", toggles == togglesBefore)
        check("and it does not begin a drag", dragsSeen == 0)

        let controlMenu = bubble.debugPressSequence(button: 0, modifiers: [.control])
        check("control-click produces the same menu",
              controlMenu?.items.map(\.title) == rightMenu?.items.map(\.title))
        check("and it does not toggle the panel either", toggles == togglesBefore)
        check("and it does not begin a drag either", dragsSeen == 0)

        if let menu = rightMenu {
            let titles = menu.items.map(\.title)
            print("  menu: \(titles.filter { !$0.isEmpty }.joined(separator: " | "))")
            check("the menu says what it is watching", titles.contains { $0.contains("3 waiting") })
            check("the menu can show or hide the sessions", titles.contains("Show sessions"))
            check("the menu can reach the data folder", titles.contains("Reveal data folder"))
            check("the menu offers Quit, clearly labelled", titles.contains(BubbleMenu.quitTitle))

            let quit = menu.items.first { $0.title == BubbleMenu.quitTitle }
            check("Quit is enabled and has somewhere to go",
                  quit?.isEnabled == true && quit?.target != nil && quit?.action != nil)
            check("Quit carries an accessibility label",
                  quit?.accessibilityLabel()?.contains("Stops watching") == true)
            check("Quit is the last thing on the menu", menu.items.last?.title == BubbleMenu.quitTitle)

            if let quit, let action = quit.action, let target = quit.target as AnyObject? {
                _ = target.perform(action)
            }
            check("choosing Quit calls the app's termination routine, once", quitTarget.quits == 1)
            check("and it is the same item constructor the menu bar uses",
                  BubbleMenu.quitItem(target: quitTarget, action: #selector(QuitProbe.menuQuit)).title
                      == quit?.title)
        }

        // A plain click must be untouched by all of the above.
        bubble.debugPressSequence(button: 0)
        check("a plain click still toggles the panel", toggles == togglesBefore + 1)
        check("and still does not drag", dragsSeen == 0)
        bubble.debugPressSequence(button: 0, dragBy: CGPoint(x: 40, y: -20))
        check("a real drag still drags", dragsSeen == 1)
        check("and a drag is not also a click", toggles == togglesBefore + 1)
        bubble.debugPressSequence(button: 0, dragBy: CGPoint(x: 2, y: 1))
        check("a shaky click is still a click, not a drag",
              dragsSeen == 1 && toggles == togglesBefore + 2)

        bubble.contextMenuProvider = nil
        bubble.onDragBegan = nil
        bubble.apply(placement: .default, size: 56)


        // MARK: Cursor policy
        // Nothing in a self-check may drive the real machine. Injection is still how each check is
        // isolated; this is the brake that makes a *missed* injection loud instead of silent.
        ActivationSafety.liveActionsForbidden = true


        print("Cursor")
        ClickCursor.apply(enabled: true)
        check("a live click target shows the pointing hand", NSCursor.current == NSCursor.pointingHand)
        ClickCursor.apply(enabled: false)
        check("something that cannot be clicked does not pretend otherwise", NSCursor.current == NSCursor.arrow)
        check("the policy tracks the events a background window is actually sent",
              ClickCursor.trackingOptions.contains(.mouseEnteredAndExited)
              && ClickCursor.trackingOptions.contains(.mouseMoved)
              && ClickCursor.trackingOptions.contains(.activeAlways))
        check("and does not ask for the one macOS suppresses for those areas",
              !ClickCursor.trackingOptions.contains(.cursorUpdate))

        // Hit-testing: which things inside a clickable card keep their own behaviour.
        let plainLabel = AttentionPanelController.label(size: 12, weight: .regular, color: .labelColor)
        plainLabel.stringValue = "decoration"
        let selectableField = NSTextField(labelWithString: "you can select me")
        selectableField.isSelectable = true
        let editableField = NSTextField(string: "you can type here")
        let liveButton = ClosureButton(title: "Live", target: nil, action: nil)
        let deadButton = ClosureButton(title: "Dead", target: nil, action: nil)
        deadButton.isEnabled = false

        check("a plain label is decoration and defers to the card it sits in",
              !ClickableView.isInteractive(plainLabel))
        check("a selectable text field keeps its own I-beam and its own clicks",
              ClickableView.isInteractive(selectableField))
        check("so does an editable one", ClickableView.isInteractive(editableField))
        check("an enabled button is its own target", ClickableView.isInteractive(liveButton))
        check("a disabled one is not, so it shows an arrow rather than a hand",
              !ClickableView.isInteractive(deadButton))

        // Interactive and decoration are different questions. A disabled button answers "no" to the
        // first and "no" to the second: it keeps its own hit and does nothing with it. Handing its
        // clicks to the card behind it would mean pressing a greyed-out control opens a terminal.
        check("a plain label is decoration", ClickableView.isDecoration(plainLabel))
        check("a selectable or editable field is not", !ClickableView.isDecoration(selectableField)
              && !ClickableView.isDecoration(editableField))
        check("and neither is a disabled button", !ClickableView.isDecoration(deadButton))

        let card = ClickableView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        var cardClicks = 0
        card.onClick = { cardClicks += 1 }
        let labelInside = AttentionPanelController.label(size: 12, weight: .regular, color: .labelColor)
        labelInside.stringValue = "reason"
        labelInside.frame = NSRect(x: 4, y: 4, width: 80, height: 16)
        let disabledInside = ClosureButton(title: "Off", target: nil, action: nil)
        disabledInside.frame = NSRect(x: 120, y: 4, width: 60, height: 20)
        disabledInside.isEnabled = false
        card.addSubview(labelInside)
        card.addSubview(disabledInside)

        check("a click on a label inside the card is the card's",
              card.hitTest(NSPoint(x: 20, y: 10)) === card)
        check("a click on a disabled button inside the card is NOT the card's",
              card.hitTest(NSPoint(x: 150, y: 12)) === disabledInside)

        card.mouseDown(with: NSEvent())
        card.isClickable = false
        card.mouseUp(with: NSEvent())
        check("disabling the card between press and release cancels the click", cardClicks == 0)

        card.isClickable = true
        card.mouseDown(with: NSEvent())
        card.mouseUp(with: NSEvent())
        check("and an ordinary press and release still activates it", cardClicks == 1)

        // Scoped invalidation: the cursor is handed back when the thing under it stops being a
        // target, and only by the view the pointer is actually over.
        let hovered = ClosureButton(title: "Hovered", target: nil, action: nil)
        hovered.hovering = true
        ClickCursor.apply(enabled: true)
        hovered.isEnabled = false
        check("disabling a control under a stationary pointer hands the cursor straight back",
              NSCursor.current == NSCursor.arrow)

        let elsewhere = ClosureButton(title: "Elsewhere", target: nil, action: nil)
        elsewhere.hovering = false
        ClickCursor.apply(enabled: true)
        elsewhere.isEnabled = false
        check("a control the pointer is not over changes nothing",
              NSCursor.current == NSCursor.pointingHand)

        let vanishing = ClickableView()
        vanishing.hovering = true
        ClickCursor.apply(enabled: true)
        vanishing.viewDidHide()
        check("a view that disappears under the pointer hands the cursor back too",
              NSCursor.current == NSCursor.arrow)

        let row = ClickableView()
        row.hovering = true
        row.isClickable = true
        ClickCursor.apply(enabled: true)
        row.isClickable = false
        check("a row that stops being clickable stops claiming to be",
              NSCursor.current == NSCursor.arrow)
        ClickCursor.release()

        // MARK: Placement

        print("Placement")
        for corner in ScreenCorner.allCases {
            bubble.apply(placement: BubblePlacement(corner: corner, offsetX: 20, offsetY: 20), size: 56)
            check("\(corner.label) stays on screen", visible.contains(bubble.frame))
        }
        bubble.apply(placement: BubblePlacement(corner: .bottomRight, offsetX: 99_999, offsetY: 99_999), size: 56)
        check("an absurd offset is clamped back on screen", visible.contains(bubble.frame))

        bubble.apply(placement: .default, size: 56)
        let before = bubble.frame
        bubble.debugDrag(by: CGPoint(x: -140, y: 90))
        check("dragging moves the bubble", abs(bubble.frame.minX - before.minX) > 100)
        check("dragging reports a placement to remember", lastPlacement != nil)
        check("the remembered placement stays on screen when reapplied", {
            guard let lastPlacement else { return false }
            bubble.apply(placement: lastPlacement, size: 56)
            return visible.contains(bubble.frame)
        }())

        // MARK: Panel

        print("Panel")
        bubble.apply(placement: .default, size: 56)
        let panel = AttentionPanelController()
        var activated: String?
        var openedSession: String?
        var snoozed: String?
        var dismissed: String?
        var copied: String?
        var collapsed = false
        panel.onActivate = { activated = $0.identity.projectName }
        panel.onOpenSession = { openedSession = $0.identity.projectName }
        var snoozeCount = 0
        var dismissCount = 0
        var dismissAllCount = 0
        panel.onSnooze = { snoozed = $0.identity.projectName; snoozeCount += 1 }
        panel.onDismiss = { dismissed = $0.identity.projectName; dismissCount += 1 }
        panel.onDismissAll = { dismissAllCount += 1 }
        panel.onCopyResume = { copied = $0.projectName }
        panel.onCollapse = { collapsed = true }

        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        panel.show()
        let frame = panel.debugFrame

        check("the panel is on screen", visible.intersects(frame))
        check("the panel is fully inside the visible area", visible.contains(frame))
        check("the panel is anchored to the bubble's edge", abs(frame.maxX - bubble.frame.maxX) < 1)
        check("the panel opens away from the screen edge", frame.minY < bubble.frame.minY || frame.minY > bubble.frame.maxY)
        check("the panel is tall enough for the session list", frame.height > 300)
        check("the panel stays a panel rather than growing to fit the widest name", frame.width <= 420)
        print("  panel: \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))")

        let labels = panel.debugTextValues
        // The old layout drew a card *and* a session row for the same session. These assertions
        // replace the ones that described that duplication: one row per full session id, with the
        // request inline in that row.
        check("the header counts what is asking for you", labels.contains { $0.contains("5 need you") })
        check("the header shows the snoozed count", labels.contains { $0.contains("2 snoozed") })
        check("a reported item is labelled by its reason", labels.contains { $0.contains("Permission needed: Bash") })
        check("the panel is titled", labels.contains { $0 == AgentAttentionVersion.displayName })
        check("the subtitle summarises attention and work", labels.contains { $0.contains("need you") && $0.contains("working") })
        check("a session that has an open request appears exactly once",
              panel.debugRowAccessibilityLabels.filter { $0.contains("Permission needed: Bash") }.count == 1)
        check("and its request is on its own row, not on a second card",
              panel.debugRowAccessibilityLabels.contains { $0.hasPrefix(SessionNameStyle.humanised("agent-attention"))
                                                           && $0.contains("Permission needed: Bash") })
        check("every row is one session and no session is drawn twice", {
            let names = panel.debugRowAccessibilityLabels.map { $0.components(separatedBy: ". ").first ?? "" }
            return Set(names).count == names.count
        }())
        check("the header offers a sound control", panel.debugAccessibilityLabels.contains { $0.hasPrefix("Sound is on") })
        check("and a settings control", panel.debugAccessibilityLabels.contains("Settings"))
        check("a discovered session is labelled awaiting first hook",
              labels.contains { $0.contains("awaiting first hook") })
        check("and counted apart from working sessions",
              labels.contains { $0.contains("1 awaiting first hook") })
        check("registry status is never shown as a state",
              !labels.contains { $0 == "busy" })
        check("nothing claims a stall, because elapsed silence is not evidence",
              !labels.contains { $0.lowercased().contains("stall") || $0.contains("No activity for") })

        // MARK: Background work

        print("Background work")
        check("a session paused on its own work says so on its own row",
              labels.contains { $0.contains("1 background shell still running") })
        check("what it is waiting on is stated in counts, not task text",
              !labels.contains { $0.contains("SECRET") })
        check("the subtitle counts it apart from attention",
              labels.contains { $0.contains("1 on background work") })
        check("and it is not in the attention count",
              labels.contains { $0.contains("5 need you") })
        check("uncertainty is named rather than folded into the quiet",
              labels.contains { $0.contains("uncertain") }
              && labels.contains { $0.contains("turn ended · state not confirmed") })

        // MARK: Names and details

        print("Names and details")
        let longName = SessionNameStyle.humanised("wundamental-exec-cashflow-truth-sensitivity-train")
        check("a long session name is rendered in full, not truncated",
              labels.contains { $0.contains(longName) })
        check("the long name wraps instead of being clipped",
              panel.debugLabels.contains { $0.stringValue.contains(longName) && $0.maximumNumberOfLines > 1 })
        check("the name is given most of the panel's width",
              panel.debugLabels.contains { $0.stringValue.contains(longName) && $0.preferredMaxLayoutWidth >= 240 })
        let clipped = panel.debugClippedLabels
        check("nothing is cut off — every label has the room its text needs"
              + (clipped.isEmpty ? "" : " (clipped: \(clipped.joined(separator: " | ")))"),
              clipped.isEmpty)
        check("technical identifiers are not squeezed into the row",
              !labels.contains { $0.contains("/dev/ttys") } && !labels.contains { $0.contains("-4f2a-") })

        // Per-row Open/Details/Snooze/Dismiss buttons are gone: the row itself is the action and
        // everything else is behind one always-present ⋯ menu, so the row never has to compete for
        // width with four controls.
        let buttons = panel.debugButtonTitles
        check("a row carries no per-row action buttons",
              !buttons.contains { $0.hasPrefix("Open") || $0 == "Details" || $0 == "Snooze"
                                  || $0 == "Dismiss" || $0 == "Copy" })
        check("every row has the secondary menu, always in the same place",
              panel.debugRowButtons(index: 0).last?.title == "•••")
        check("and the menu says whose actions it holds",
              panel.debugAccessibilityLabels.contains { $0.hasPrefix("More actions for ") })

        let a11y = panel.debugAccessibilityLabels
        check("every row carries an accessibility label", a11y.contains { $0.contains("Permission needed: Bash") })
        check("and that label says what clicking it will do",
              panel.debugRowAccessibilityLabels.allSatisfy {
                  $0.contains("Open the Ghostty tab") || $0.contains("Bring this session")
                  || $0.contains("recent conversation")
              })
        check("the tooltip says the same thing the label does",
              panel.debugRowTooltips.count == panel.debugRowCount)
        check("the collapse control is labelled", a11y.contains { $0.contains("Collapse the panel") })

        print("Cursor coverage")
        let targets = panel.debugClickTargets
        check("the panel has click targets to check", !targets.isEmpty)
        // `.cursorUpdate` alone was the bug. Apple is explicit that `cursorUpdate(with:)` is **not**
        // sent for a tracking area registered with `.activeAlways` — which is every area in this
        // app, because the bubble and the panel never become key. Enter and exit *are* delivered,
        // and so is movement once the window accepts it, so those are what the policy has to hang
        // on. The options are still asserted, but only as scaffolding for the behaviour below.
        check("every click target is tracked for the events a non-key window actually receives",
              targets.allSatisfy { target in
                  target.updateTrackingAreas()
                  return target.trackingAreas.contains {
                      $0.options.contains(.mouseEnteredAndExited)
                      && $0.options.contains(.mouseMoved)
                      && $0.options.contains(.activeAlways)
                  }
              })
        check("no label offers a text cursor over something you are meant to click",
              panel.debugLabels.allSatisfy { !$0.isSelectable && !$0.isEditable })

        // MARK: Arriving from a text app

        print("Arriving with an I-beam")
        // The live report, reproduced as closely as this can be without a pointer: the cursor is an
        // I-beam because it was last over a terminal, and the pointer then enters one of our
        // targets. Nothing here calls `cursorUpdate` — that is precisely the message AppKit does not
        // send us — so what is exercised is the delivery path a background window really gets.
        func arrivingFromText(_ view: NSView, _ label: String, expectHand: Bool) {
            view.updateTrackingAreas()
            NSCursor.iBeam.set()
            view.mouseEntered(with: NSEvent())
            check("entering \(label) with an I-beam \(expectHand ? "gives the hand" : "gives the arrow back")",
                  NSCursor.current == (expectHand ? NSCursor.pointingHand : NSCursor.arrow))

            // Another application re-asserting its own cursor while the pointer is still inside
            // ours. Movement is the only chance to take it back.
            NSCursor.iBeam.set()
            view.mouseMoved(with: NSEvent())
            check("and moving inside \(label) takes it back from whatever reset it",
                  NSCursor.current == (expectHand ? NSCursor.pointingHand : NSCursor.arrow))

            view.mouseExited(with: NSEvent())
            check("leaving \(label) hands the arrow back", NSCursor.current == NSCursor.arrow)
        }

        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        arrivingFromText(bubble.debugView, "the bubble", expectHand: true)
        if let row = panel.debugClickTargets.first(where: { $0 is SessionRowView }) {
            arrivingFromText(row, "a session row", expectHand: true)
        } else {
            check("a session row was available to check", false)
        }
        if let menuButton = panel.debugOverflowButton(index: 0) {
            arrivingFromText(menuButton, "a row's ⋯ button", expectHand: true)
            menuButton.isEnabled = false
            arrivingFromText(menuButton, "a disabled control", expectHand: false)
            menuButton.isEnabled = true
        } else {
            check("a row button was available to check", false)
        }

        // Two tracking areas can overlap — a row's and a control inside it — and both would be told
        // about the same movement. That is only a problem when they disagree, which today they
        // cannot: a row contains labels (decoration, no cursor of their own) and one enabled ⋯
        // button. This asserts that arrangement rather than adding location arithmetic for a case
        // that does not exist; if a disabled control is ever put inside a row, this fails and the
        // question gets asked properly.
        check("no clickable row contains a control that would claim a different cursor",
              panel.debugClickTargets.compactMap { $0 as? SessionRowView }.allSatisfy { row in
                  AttentionPanelController.buttons(in: row).allSatisfy(\.isEnabled)
              })
        check("and the text inside a row is decoration, which keeps no cursor of its own",
              panel.debugLabels.allSatisfy { ClickableView.isDecoration($0) })

        // EVERY visible control, not a representative one. The report was "all clickable controls",
        // and the header controls, the disclosure and both ordinary windows' buttons are the same
        // shared class as the row's — they were simply never checked.
        func everyControlTakesTheCursor(_ buttons: [ClosureButton], _ where_: String) {
            check("\(where_) has controls to check", !buttons.isEmpty)
            let titles = buttons.map { $0.title.isEmpty ? ($0.accessibilityLabel() ?? "?") : $0.title }
            print("  \(where_): \(titles.joined(separator: " | "))")
            let allTakeIt = buttons.allSatisfy { button in
                button.updateTrackingAreas()
                NSCursor.iBeam.set()
                button.mouseEntered(with: NSEvent())
                let onEntry = NSCursor.current == (button.isEnabled ? NSCursor.pointingHand : NSCursor.arrow)
                NSCursor.iBeam.set()
                button.mouseMoved(with: NSEvent())
                let onMove = NSCursor.current == (button.isEnabled ? NSCursor.pointingHand : NSCursor.arrow)
                button.mouseExited(with: NSEvent())
                return onEntry && onMove && NSCursor.current == NSCursor.arrow
            }
            check("every control in \(where_) takes the cursor on entry and on movement", allTakeIt)
        }

        everyControlTakesTheCursor(
            AttentionPanelController.buttons(in: panel.debugContentView ?? NSView()),
            "the panel — sound, settings, dismiss all, collapse, disclosure and each row's ⋯")

        let cursorContext = SessionContextWindow.synchronous(query: { _ in
            SessionContextAnswer(sessionID: "sess-cursor", identity: .verifiedLive, process: "alive",
                                 attention: .init(known: true, certainty: "waiting", kind: "approval",
                                                  reason: "Permission needed: Bash", waitingSeconds: 30,
                                                  occurrences: 1, snoozed: false, queueIsFresh: true,
                                                  appIsRunning: true, queueAgeSeconds: 1,
                                                  unprocessedEvents: 0, caveats: []),
                                 context: nil, generatedAt: now)
        })
        cursorContext.linkStatus = { _ in false }         // both Open session and Link are visible
        cursorContext.onOpenSession = { _, _ in }
        cursorContext.onLinkTerminal = { _ in }
        var cursorIdentity = items[0].identity
        cursorIdentity.tty = "/dev/ttys004"
        cursorContext.show(identity: cursorIdentity, attention: nil)
        everyControlTakesTheCursor(cursorContext.debugButtons,
                                   "the conversation window — Open session, Link, Refresh, Close")
        check("the conversation window accepts the movement its controls need",
              cursorContext.debugWindowAcceptsMouseMoved)
        // And the text keeps its own I-beam: it is text, and selecting it is the point.
        check("the transcript is still selectable, with the cursor macOS gives text",
              cursorContext.debugTranscriptIsSelectable)
        check("and the identity lines beside it are too",
              !cursorContext.debugSelectableFields.isEmpty
              && cursorContext.debugSelectableFields.allSatisfy { !ClickableView.isDecoration($0) })
        cursorContext.close()

        let cursorPairing = PairingWindow.synchronous(ghostty: MockGhostty())
        cursorPairing.show(identity: cursorIdentity, existing: nil)
        everyControlTakesTheCursor(cursorPairing.debugButtons,
                                   "the linking window — Unlink, Read, Confirm, Close")
        check("the linking window accepts the movement its controls need",
              cursorPairing.debugWindowAcceptsMouseMoved)
        check("and its selectable identity text keeps its own cursor",
              !cursorPairing.debugSelectableFields.isEmpty)
        cursorPairing.close()

        // What these checks can and cannot say. `NSCursor.current` is this application's cursor;
        // AppKit's own header says it "isn't necessarily the cursor that is currently being
        // displayed, as the system may be showing the cursor for another running application". So
        // everything above proves the handlers run and set the right cursor *for this process* —
        // and nothing about the pointer on screen.
        check("the diagnostics that can answer the live question are off unless asked for",
              !CursorDiagnostics.isEnabled)
        check("and a cursor is compared by shape, not by object identity",
              CursorDiagnostics.fingerprint(NSCursor.iBeam) != CursorDiagnostics.fingerprint(NSCursor.pointingHand)
              && CursorDiagnostics.fingerprint(NSCursor.iBeam) == CursorDiagnostics.fingerprint(NSCursor.iBeam))
        check("an unavailable system reading is uncertain, never a match or a mismatch",
              CursorDiagnostics.fingerprint(nil) == "unknown(nil)"
              && CursorDiagnostics.matches(nil, NSCursor.pointingHand) == "unknown")
        check("and a capture is bounded, not open-ended",
              CursorDiagnostics.maximumRecords > 0 && CursorDiagnostics.maximumBytes > 0
              && CursorDiagnostics.maximumDuration > 0 && !CursorDiagnostics.isExhausted)

        // Movement has to be delivered at all: a borderless panel receives none unless its window
        // asks for it.
        check("the panel's window accepts the movement it needs", panel.debugWindowAcceptsMouseMoved)
        check("and the bubble's does too", bubble.debugWindowAcceptsMouseMoved)
        check("without either window becoming key — the cursor is not worth stealing focus for",
              !panel.debugWindowCanBecomeKey && !bubble.debugWindowCanBecomeKey)

        // A re-render replaces the row under a stationary pointer. Whatever else happens, the
        // pointer must not be left holding a hand for a row that no longer exists, nor an I-beam.
        if let row = panel.debugClickTargets.first(where: { $0 is SessionRowView }) {
            NSCursor.iBeam.set()
            row.mouseEntered(with: NSEvent())
            panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4,
                         now: now, anchor: bubble.frame)
            check("a re-render under a stationary pointer leaves no stale cursor behind",
                  NSCursor.current == NSCursor.arrow)
        }
        ClickCursor.release()

        // MARK: Clicking away

        print("Clicking away")
        // The rule, exercised directly. A global mouse monitor only ever sees events that went to
        // *another* application and cannot consume them, so nothing is taken from whatever the user
        // clicked; and it needs no Accessibility grant, which is a keyboard-monitoring requirement.
        var fakeNow = Date()
        let watcher = OutsideClickWatcher(clock: { fakeNow })
        var collapses = 0
        watcher.onOutsideClick = {
            if watcher.shouldCollapse(panelIsExpanded: true, at: fakeNow) { collapses += 1 }
        }

        check("a click outside closes an open panel", watcher.shouldCollapse(panelIsExpanded: true, at: fakeNow))
        check("and does nothing when the panel is already closed",
              !watcher.shouldCollapse(panelIsExpanded: false, at: fakeNow))

        watcher.debugSetMenuTracking(true)
        check("our own menu is open, so a click belongs to the menu, not to closing the panel",
              !watcher.shouldCollapse(panelIsExpanded: true, at: fakeNow))
        watcher.debugSetMenuTracking(false)
        check("the click that closed the menu does not also close the panel",
              !watcher.shouldCollapse(panelIsExpanded: true, at: fakeNow))
        fakeNow = fakeNow.addingTimeInterval(watcher.settleAfterMenu + 0.1)
        check("a later click does close it", watcher.shouldCollapse(panelIsExpanded: true, at: fakeNow))

        watcher.handleOutsideClick()
        check("the monitor's callback runs the same rule", collapses == 1)

        // Closing is presentation, and only presentation.
        let itemsBefore = panel.debugTextValues
        panel.hide()
        panel.show()
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        check("closing and reopening leaves every card exactly as it was",
              panel.debugTextValues == itemsBefore)
        check("nothing was dismissed, snoozed or resolved by hiding the panel",
              snoozed == nil && dismissed == nil && activated == nil && copied == nil)

        watcher.start()
        check("the watcher installs its monitor", watcher.isRunning)
        watcher.stop()
        check("and removes it again", !watcher.isRunning)

        // MARK: Row controls

        print("Row controls")
        let rowButtons = [panel.debugOverflowButton(index: 0)].compactMap { $0 }
        let rowMenuTitles = panel.debugRowMenu(index: 0)?.items.map(\.title) ?? []
        print("  row 0 menu: \(rowMenuTitles.joined(separator: " | "))")
        check("the ⋯ menu offers the conversation", rowMenuTitles.contains("Recent conversation…"))
        check("and the notification actions, for a row that has a notification",
              rowMenuTitles.contains("Snooze this notification")
              && rowMenuTitles.contains("Dismiss this notification"))
        check("dismiss says what it does and does not touch",
              (panel.debugRowMenu(index: 0)?.items.first { $0.title == "Dismiss this notification" }?.toolTip ?? "")
                  .contains("session and its work are untouched"))
        check("and the technical detail is one level down, not on the row",
              rowMenuTitles.contains("Details"))
        check("the copy fallback is still there for a session with nowhere to go",
              rowMenuTitles.contains("Copy session details and resume command"))
        check("and it is user-driven, never automatic", copied == nil)
        check("choosing it copies that row's session",
              panel.debugClickRowMenuItem(index: 0, titled: "Copy session details and resume command")
              && copied != nil)
        check("every menu entry that does something is enabled",
              (panel.debugRowMenu(index: 0)?.items ?? [])
                  .filter { $0.action != nil }.allSatisfy(\.isEnabled))
        check("the ⋯ button carries the shared cursor handling",
              rowButtons.allSatisfy { button in
                  button.updateTrackingAreas()
                  return button.trackingAreas.contains {
                      $0.options.contains(.mouseEnteredAndExited)
                      && $0.options.contains(.mouseMoved)
                      && $0.options.contains(.activeAlways)
                  }
              })
        check("hovering it asks for the pointing hand", {
            guard let menu = rowButtons.first else { return false }
            NSCursor.iBeam.set()
            menu.mouseEntered(with: NSEvent())
            let hand = NSCursor.current == NSCursor.pointingHand
            menu.mouseExited(with: NSEvent())
            return hand && NSCursor.current == NSCursor.arrow
        }())
        check("and a disabled one asks for the arrow instead", {
            guard let menu = rowButtons.first else { return false }
            menu.isEnabled = false
            NSCursor.iBeam.set()
            menu.mouseEntered(with: NSEvent())
            let arrow = NSCursor.current == NSCursor.arrow
            menu.isEnabled = true
            menu.mouseExited(with: NSEvent())
            return arrow
        }())

        // A quiet session has nothing to snooze or dismiss, and must not offer it.
        let quietRow = panel.debugRowAccessibilityLabels.firstIndex { $0.hasPrefix(SessionNameStyle.humanised("alpha")) }
        if let quietRow {
            let quietTitles = panel.debugRowMenu(index: quietRow)?.items.map(\.title) ?? []
            check("a session with no open request offers no snooze or dismiss",
                  !quietTitles.contains("Snooze this notification")
                  && !quietTitles.contains("Dismiss this notification"))
            check("but still offers its conversation", quietTitles.contains("Recent conversation…"))
        } else {
            check("a session with no open request was found to check", false)
        }

        // MARK: Names, branches and conversation

        print("Names and branches")
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        let branchLabels = panel.debugTextValues
        check("the worktree is the row's name, not the generated registry label",
              branchLabels.contains(SessionNameStyle.humanised("alpha"))
              && !branchLabels.contains { $0.contains("redmy-e9") })
        check("the branch read from the directory is on the row",
              branchLabels.contains { $0.hasPrefix("cs/alpha · ") })
        check("the generated registry label is kept for Details, not thrown away", {
            let alphaRow = panel.debugRowAccessibilityLabels.firstIndex { $0.hasPrefix(SessionNameStyle.humanised("alpha")) }
            let details = alphaRow.flatMap { panel.debugDetailsMenu(rowIndex: $0)?.items.map(\.title) } ?? []
            return details.contains { $0.contains("redmy-e9") && $0.contains("client-generated") }
        }())
        check("a branch merely stamped at launch is never shown as the current one",
              !branchLabels.contains { $0 == "main" })

        // The branch belongs on a row that is asking for you too — that is exactly when "which
        // worktree is this" matters. It was previously shown only on quiet rows.
        var urgentSessions = sessions
        // The reading has to be about the directory the session is actually in — a branch read
        // somewhere else is not this session's branch, and is no longer accepted as one.
        let urgentIndex = urgentSessions.count - 2
        urgentSessions[urgentIndex].identity.branch =
            .git(.branch("cs/red658-plan-vs-ledger"), path: urgentSessions[urgentIndex].identity.cwd, at: now)
        panel.render(items: items, sessions: urgentSessions, snoozedCount: 2, maxVisible: 4,
                     now: now, anchor: bubble.frame)
        let urgentRow = panel.debugRowAccessibilityLabels.firstIndex { $0.contains("Permission needed: Bash") }
        check("a row with an open request still shows its branch", panel.debugTextValues.contains("cs/red658-plan-vs-ledger"))
        check("and the request is still the line under it", urgentRow != nil)
        check("nothing is clipped by the extra line", panel.debugClippedLabels.isEmpty)

        // A finished turn is news, not a demand: same row, same place, calm colour.
        let completionColour = AttentionPanelController.headlineColor(.workComplete)
        check("a completed turn is not styled like an approval",
              completionColour != AttentionPanelController.headlineColor(.approval))
        check("approvals, questions and errors all keep the one urgent colour",
              AttentionPanelController.headlineColor(.approval) == AttentionPanelController.headlineColor(.question)
              && AttentionPanelController.headlineColor(.error) == AttentionPanelController.headlineColor(.approval))
        check("and styling changed nothing about what counts as needing you",
              panel.debugTextValues.contains { $0.contains("5 need you") })

        var contextRequests: [SessionIdentity] = []
        panel.onShowContext = { contextRequests.append($0) }
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        let detailTitles = panel.debugDetailsMenu(rowIndex: 0)?.items.map(\.title) ?? []
        print("  details: \(detailTitles.prefix(12).joined(separator: " | "))")
        check("Details still carries the full session id", detailTitles.contains { $0.hasPrefix("session  ") })

        let firstRowName = panel.debugRowAccessibilityLabels.first?.components(separatedBy: ". ").first ?? ""
        check("the ⋯ menu offers the recent conversation",
              panel.debugClickRowMenuItem(index: 0, titled: "Recent conversation…"))
        check("choosing it asks for exactly that session's conversation",
              contextRequests.count == 1
              && contextRequests.first.map { SessionNameStyle.humanised($0.projectName) } == firstRowName)

        print("Recent conversation window")
        let sampleContext = SessionContext(
            sessionID: "sess-ui-check",
            availability: .read,
            transcriptPath: "/tmp/sess-ui-check.jsonl",
            readAt: now,
            bytesRead: 4096,
            tailTruncated: true,
            messages: [
                .init(role: "user", at: now, excerpt: "rework the export to v3", truncated: false),
                .init(role: "assistant", at: now, excerpt: "Done — the schema switch is in.", truncated: false),
            ],
            questions: [
                .init(question: "Which schema?", options: ["v2", "v3"], askedAt: now,
                      answered: "notObserved", correlationComplete: false),
            ],
            notes: ["Read the last 1024 KiB of a 12000 KiB transcript; anything older is not shown."]
        )
        let body = SessionContextWindow.render(sampleContext)
        check("it attributes what was said", body.contains("You") && body.contains("Claude"))
        check("it quotes the message, not a summary of it", body.contains("rework the export to v3"))
        check("it says how much it read and when", body.contains("KiB at") && body.contains("tail only"))
        check("a question with no result seen is never called unanswered",
              body.contains("not evidence that one is owed") && !body.contains("no answer in the transcript"))
        check("it says plainly what it is", body.contains("Excerpts, not a summary"))

        let denied = SessionContext(sessionID: "sess-ui-check", availability: .denied, readAt: now,
                                    notes: [SessionContextReader.note(for: .denied)])
        let deniedBody = SessionContextWindow.render(denied)
        check("an unreadable transcript is reported as such", deniedBody.contains("could not be opened"))
        check("and the known prompt state is explicitly still valid",
              deniedBody.contains("comes from hooks and stands on its own"))

        // The attention line comes from the shared query, and says *known* only when the shared
        // trust model does. These are the three states it has to tell apart.
        func answer(certainty: String, known: Bool, kind: String?, identity: SessionContextAnswer.Identity = .verifiedLive) -> SessionContextAnswer {
            SessionContextAnswer(
                sessionID: "sess-ui-check", identity: identity, process: "alive",
                attention: .init(known: known, certainty: certainty, kind: kind,
                                 reason: kind == nil ? nil : "Permission needed: Bash",
                                 waitingSeconds: 30, occurrences: 1, snoozed: false,
                                 queueIsFresh: known, appIsRunning: true, queueAgeSeconds: 1,
                                 unprocessedEvents: 0,
                                 caveats: known ? [] : ["The queue could not be trusted at the moment of asking."]),
                context: sampleContext, generatedAt: now)
        }

        check("an open request the queue vouches for is stated as live",
              SessionContextWindow.attentionLine(answer(certainty: "waiting", known: true, kind: "approval"))
                  .contains("reported by a hook, and still open"))
        check("the same request from an untrustworthy queue is labelled a saved record, not certainty",
              SessionContextWindow.attentionLine(answer(certainty: "waiting", known: false, kind: "approval"))
                  .contains("a saved record"))
        check("a positively quiet session says so",
              SessionContextWindow.attentionLine(answer(certainty: "none", known: true, kind: nil))
                  .contains("No open request"))
        check("an uncertain session is never called quiet",
              SessionContextWindow.attentionLine(answer(certainty: "uncertain", known: false, kind: nil))
                  .contains("unknown (uncertain)"))
        check("a session Agent Warden does not track shows no conversation at all",
              SessionContextWindow.render(SessionContextAnswer(
                  sessionID: "sess-ui-check", identity: .notTracked, process: "unidentified",
                  attention: .init(known: false, certainty: "unknown", kind: nil, reason: nil,
                                   waitingSeconds: nil, occurrences: nil, snoozed: nil,
                                   queueIsFresh: false, appIsRunning: nil, queueAgeSeconds: nil,
                                   unprocessedEvents: 0,
                                   caveats: ["This session is not in Agent Warden's queue."]),
                  context: nil, generatedAt: now))
                  .contains("not tracking this session"))

        // MARK: Open session, from the conversation window

        print("Open session from a conversation")
        // A real `SessionContextWindow`, driven through its own buttons. Everything beyond it is a
        // stand-in: no activator, no adapter, no application. What is being checked is which
        // request the window makes, with which session id, and what it does with the answer.
        var openRequests: [String] = []
        var linkRequests: [String] = []
        var openReply: ((ContextOpenResult) -> Void)?
        let liveIdentity = SessionIdentity(sessionID: "sess-open-check", cwd: "/Users/dev/code/alpha",
                                           claudePID: 4242, claudePIDStartedAt: 1,
                                           termProgram: "ghostty",
                                           terminalAppPath: "/Applications/Ghostty.app")
        var linkExists = true

        let contextWindow = SessionContextWindow.synchronous(query: { _ in
            SessionContextAnswer(sessionID: "sess-open-check", identity: .verifiedLive, process: "alive",
                                 attention: .init(known: true, certainty: "waiting", kind: "approval",
                                                  reason: "Permission needed: Bash", waitingSeconds: 30,
                                                  occurrences: 1, snoozed: false, queueIsFresh: true,
                                                  appIsRunning: true, queueAgeSeconds: 1,
                                                  unprocessedEvents: 0, caveats: []),
                                 context: sampleContext, generatedAt: now)
        })
        contextWindow.linkStatus = { _ in linkExists }
        contextWindow.onLinkTerminal = { linkRequests.append($0) }
        contextWindow.onOpenSession = { sessionID, reply in
            openRequests.append(sessionID)
            openReply = reply
        }
        contextWindow.show(identity: liveIdentity, attention: items.first)

        check("the conversation window keeps Refresh and Close",
              contextWindow.debugButtonTitles.contains("Refresh") && contextWindow.debugButtonTitles.contains("Close"))
        check("and now offers Open session", contextWindow.debugButtonTitles.contains("Open session"))
        check("which says what it will do while a link exists",
              contextWindow.debugOpenTooltip.contains("tab you linked")
              && contextWindow.debugOpenAccessibilityLabel.contains("linked Ghostty tab"))
        check("and nothing offers to link while one already holds", !contextWindow.debugLinkOffered)

        contextWindow.debugClickOpen()
        check("clicking it asks for this exact session, by full id", openRequests == ["sess-open-check"])
        check("a second click cannot queue a second navigation", {
            contextWindow.debugClickOpen()
            return openRequests.count == 1 && !contextWindow.debugOpenEnabled
        }())
        let bodyBeforeOpen = contextWindow.debugBodyText
        let attentionBeforeOpen = contextWindow.debugAttentionLine

        openReply?(.landed("Switched to alpha in Ghostty (the tab you linked)"))
        check("a landing is reported in the window", contextWindow.debugNavigationLine.contains("Switched to alpha"))
        check("and the conversation is exactly as it was", contextWindow.debugBodyText == bodyBeforeOpen)
        check("and the attention line is untouched — opening a tab dismisses nothing",
              contextWindow.debugAttentionLine == attentionBeforeOpen)
        check("the action is usable again afterwards", contextWindow.debugOpenEnabled)

        // A saved link that no longer holds: the failure is explained and relinking is offered,
        // without losing the transcript or the request.
        contextWindow.debugClickOpen()
        openReply?(.failed("Could not confirm the linked tab — Ghostty changed while the link was being checked.",
                           offerRelink: true))
        check("a stale link explains itself", contextWindow.debugNavigationLine.contains("Could not confirm"))
        check("and offers the way to fix it", contextWindow.debugLinkOffered)
        check("with the conversation and the request both intact",
              contextWindow.debugBodyText == bodyBeforeOpen
              && contextWindow.debugAttentionLine == attentionBeforeOpen)
        contextWindow.debugClickLink()
        check("relinking goes to the pairing workflow for that same session",
              linkRequests == ["sess-open-check"])
        check("and says what to do next", contextWindow.debugNavigationLine.contains("linking window"))

        // No link at all: the pairing workflow, never an app-only raise.
        linkExists = false
        openRequests.removeAll()
        linkRequests.removeAll()
        contextWindow.show(identity: liveIdentity, attention: items.first)
        check("with no link, the action says so before it is pressed",
              contextWindow.debugOpenTooltip.contains("no linked tab yet"))
        check("and linking is offered up front", contextWindow.debugLinkOffered)
        contextWindow.debugClickOpen()
        openReply?(.needsLink("No Ghostty tab is linked to this session yet. Pick it in the linking window, "
                              + "then press Open session again."))
        check("pressing it routes to linking rather than raising an application",
              contextWindow.debugNavigationLine.contains("linking window"))
        check("and no fallback was offered instead",
              !contextWindow.debugNavigationLine.lowercased().contains("copied")
              && !contextWindow.debugNavigationLine.lowercased().contains("clipboard"))

        // The window moves on, or closes, while the terminal is still being asked.
        linkExists = true
        contextWindow.show(identity: liveIdentity, attention: items.first)
        contextWindow.debugClickOpen()
        let staleReply = openReply
        contextWindow.close()
        staleReply?(.landed("Switched to something else entirely"))
        check("a result arriving after the window closed changes nothing",
              !contextWindow.debugNavigationLine.contains("something else entirely"))

        // The native close: the red button and ⌘W, through AppKit's own machinery rather than our
        // Close button. This is the path that had no delegate at all.
        contextWindow.show(identity: liveIdentity, attention: items.first)
        contextWindow.debugClickOpen()
        let nativeReply = openReply
        contextWindow.debugPerformNativeClose()
        check("the native close really closed the window", !contextWindow.debugIsVisible)
        nativeReply?(.landed("Switched after the title bar close"))
        check("and a result arriving after it changes nothing",
              !contextWindow.debugNavigationLine.contains("title bar close"))
        check("the window is still reusable afterwards", {
            contextWindow.show(identity: liveIdentity, attention: items.first)
            return contextWindow.debugIsVisible && contextWindow.debugOpenEnabled
                && contextWindow.debugBodyText.contains("rework the export to v3")
        }())

        // The transcript read has the same problem and needed the same guard: the *same* session,
        // closed and reopened while a read was out.
        var pendingRead: (() -> Void)?
        var readCount = 0
        let readWindow = SessionContextWindow(
            query: { _ in
                readCount += 1
                return SessionContextAnswer(
                    sessionID: "sess-open-check", identity: .verifiedLive, process: "alive",
                    attention: .init(known: true, certainty: "waiting", kind: "approval",
                                     reason: "Permission needed: Bash", waitingSeconds: 30,
                                     occurrences: 1, snoozed: false, queueIsFresh: true,
                                     appIsRunning: true, queueAgeSeconds: 1, unprocessedEvents: 0,
                                     caveats: ["read number \(readCount)"]),
                    context: sampleContext, generatedAt: now)
            },
            runOffMain: { $0() },
            runOnMain: { work in pendingRead = work })      // the result is held, not delivered
        readWindow.linkStatus = { _ in true }
        readWindow.show(identity: liveIdentity, attention: nil)
        let firstRead = pendingRead
        readWindow.debugPerformNativeClose()
        firstRead?()
        check("a transcript read that lands after a native close is dropped",
              readWindow.debugBodyText == "Reading the transcript…")

        // And the case an id check alone would wave through: same session, asked twice.
        readWindow.show(identity: liveIdentity, attention: nil)
        let staleRead = pendingRead
        readWindow.show(identity: liveIdentity, attention: nil)   // asked again, same id
        let freshRead = pendingRead
        freshRead?()
        let freshBody = readWindow.debugBodyText
        staleRead?()
        check("and an older read for the SAME session cannot replace a newer one",
              readWindow.debugBodyText == freshBody
              && readWindow.debugAttentionLine.contains("Permission needed: Bash"))
        readWindow.close()

        var switchedIdentity = liveIdentity
        switchedIdentity.sessionID = "sess-other-session"
        contextWindow.show(identity: liveIdentity, attention: items.first)
        contextWindow.debugClickOpen()
        let crossReply = openReply
        contextWindow.show(identity: switchedIdentity, attention: nil)
        crossReply?(.landed("Switched to the previous session"))
        check("nor does one that belongs to the session you have navigated away from",
              !contextWindow.debugNavigationLine.contains("previous session"))

        panel.onShowContext = nil

        // MARK: Version

        print("Version and freshness")
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        check("the panel shows the running version, bottom right",
              panel.debugTextValues.contains(AgentAttentionVersion.string))
        check("and it is the binary's own version, not a second copy of the number",
              panel.debugVersionLabelText == AgentAttentionVersion.string)
        check("the version is announced to VoiceOver too",
              panel.debugAccessibilityLabels.contains { $0.contains("version \(AgentAttentionVersion.string)") })
        check("the footer says when this list was last drawn, on the left",
              panel.debugTextValues.contains("updated \(AttentionPanelController.clockString(now))"))
        check("and that timestamp follows the render, so a frozen list is visible as one", {
            let later = now.addingTimeInterval(3600)
            panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4,
                         now: later, anchor: bubble.frame)
            let moved = panel.debugTextValues.contains("updated \(AttentionPanelController.clockString(later))")
            panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4,
                         now: now, anchor: bubble.frame)
            return moved
        }())

        // MARK: Sound and settings

        print("Sound and settings")
        var applied: [PanelSetting] = []
        var acceptChange = true
        panel.settings = AttentionConfig.default
        panel.onSettingChange = { change in
            applied.append(change)
            guard acceptChange else { return false }
            switch change {
            case .soundEnabled(let on): panel.settings.soundEnabled = on
            case .speechEnabled(let on): panel.settings.speechEnabled = on
            case .chimeEnabled(let on): panel.settings.chimeEnabled = on
            case .notifyOnWorkComplete(let on): panel.settings.notifyOnWorkComplete = on
            case .notifyOnIdle(let on): panel.settings.notifyOnIdle = on
            case .includeHookMessages(let on): panel.settings.includeHookMessages = on
            case .bubbleEnabled(let on): panel.settings.bubbleEnabled = on
            case .snoozeDurationSeconds(let seconds): panel.settings.snoozeDurationSeconds = seconds
            }
            return true
        }
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        check("sound starts on, and says so in words a screen reader can read",
              panel.debugAccessibilityLabels.contains { $0.hasPrefix("Sound is on") })
        check("clicking it mutes", panel.debugClickPanelButton(labelledWith: "Sound is on"))
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        check("and the control now shows a distinct muted state",
              panel.debugAccessibilityLabels.contains { $0.contains("is muted") }
              && !panel.debugAccessibilityLabels.contains { $0.hasPrefix("Sound is on") })
        check("muting is one change, applied once", applied.count == 1)

        // Muting must silence speech without forgetting that speech was wanted.
        panel.settings.speechEnabled = true
        let mutedMenu = panel.debugSettingsMenu()
        let speechEntry = mutedMenu.items.first { $0.title == "Speak alerts aloud" }
        check("speech is still remembered as wanted", speechEntry?.state == .on)
        check("but it cannot be operated while muted, and says why",
              speechEntry?.isEnabled == false && (speechEntry?.toolTip ?? "").contains("Unavailable while muted"))
        check("and the menu states plainly that nothing will be spoken",
              mutedMenu.items.contains { $0.title.contains("silent while muted") })
        check("the config agrees: audible needs both switches",
              !panel.settings.speechIsAudible && panel.settings.speechEnabled)

        check("unmuting restores what was already set, and announces nothing older",
              panel.debugClickPanelButton(labelledWith: "is muted"))
        check("sound is back on with speech exactly as it was",
              panel.settings.soundEnabled && panel.settings.speechEnabled && panel.settings.speechIsAudible)
        check("no old event was replayed by unmuting", applied.count == 2)

        // The chime: opt-in, previewable, and never played by this check. The player here records
        // instead of sounding, so everything below is about the rules, not about the speaker.
        let recorder = RecordingChimePlayer()
        let scheduler = ChimeScheduler(player: recorder)
        var previews = 0
        panel.onPreviewChime = { previews += 1; scheduler.preview() }

        check("the chime is off until it is asked for",
              AttentionConfig.default.chimeEnabled == false
              && AttentionConfig.default.chimeIsAudible == false)
        let audioMenu = panel.debugSettingsMenu()
        let chimeEntry = audioMenu.items.first { $0.title == "Attention chime" }
        let previewEntry = audioMenu.items.first { $0.title == "Preview chime" }
        check("settings offer the chime and a way to hear it",
              chimeEntry != nil && previewEntry != nil)
        check("and it is shown as off", chimeEntry?.state == .off)
        check("sound on with nothing set to make a noise says exactly that", {
            let wantedSpeech = panel.settings.speechEnabled
            panel.settings.speechEnabled = false
            let silent = panel.debugSettingsMenu()
            panel.settings.speechEnabled = wantedSpeech
            return panel.settings.soundEnabled && silent.items
                .contains { $0.title.contains("No alert sound is on") }
        }())

        check("previewing plays once, on the click, and changes no preference", {
            let before = panel.settings
            previewEntry.map { NSApp.sendAction($0.action!, to: $0.target, from: $0) }
            return previews == 1 && recorder.played == 1 && panel.settings == before
        }())
        check("the preview is a sound, not a promise of one",
              recorder.last?.samples.isEmpty == false
              && (recorder.last?.duration ?? 0) <= AttentionChime.maximumDuration)

        check("turning the chime on is one saved change", {
            let before = applied.count
            chimeEntry.map { NSApp.sendAction($0.action!, to: $0.target, from: $0) }
            return panel.settings.chimeEnabled && applied.count == before + 1
        }())
        check("switching it on plays nothing by itself", recorder.played == 1)
        check("and the misleading note is gone once something is set to sound", {
            let wantedSpeech = panel.settings.speechEnabled
            panel.settings.speechEnabled = false
            let sounding = panel.debugSettingsMenu()
            panel.settings.speechEnabled = wantedSpeech
            return !sounding.items.contains { $0.title.contains("No alert sound is on") }
        }())

        // Muted: remembered, unavailable, and silent.
        panel.settings.soundEnabled = false
        let mutedAudio = panel.debugSettingsMenu()
        check("muting leaves the chime remembered but unavailable",
              mutedAudio.items.first { $0.title == "Attention chime" }?.state == .on
              && mutedAudio.items.first { $0.title == "Attention chime" }?.isEnabled == false)
        check("and the preview cannot be triggered while muted",
              mutedAudio.items.first { $0.title == "Preview chime" }?.isEnabled == false)
        check("the config agrees the chime is silent while muted", !panel.settings.chimeIsAudible)
        panel.settings.soundEnabled = true
        panel.settings.chimeEnabled = false

        let settingsMenu = panel.debugSettingsMenu()
        let settingTitles = settingsMenu.items.map(\.title)
        print("  settings: \(settingTitles.prefix(10).joined(separator: " | "))")
        check("settings cover which events raise a notification",
              settingTitles.contains("A turn finishes with nothing left running")
              && settingTitles.contains("A session reports it is waiting at the prompt"))
        check("and the snooze length", settingTitles.contains("Snooze for"))
        check("and the bubble", settingTitles.contains("Show the floating bubble"))
        check("the ticks are read from the live settings, not kept as a second copy", {
            panel.settings.notifyOnIdle = false
            let entry = panel.debugSettingsMenu().items.first { $0.title == "A session reports it is waiting at the prompt" }
            panel.settings.notifyOnIdle = true
            return entry?.state == .off
        }())
        check("turning both generic notifications off still says approvals come through", {
            panel.settings.notifyOnWorkComplete = false
            panel.settings.notifyOnIdle = false
            let menu = panel.debugSettingsMenu()
            panel.settings.notifyOnWorkComplete = true
            panel.settings.notifyOnIdle = true
            return menu.items.contains { $0.title.contains("Approvals, questions and errors still come through") }
        }())

        // MARK: The orchestration contract

        print("Orchestration contract")
        let contractRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-uicheck-contract-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: contractRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: contractRoot) }
        let agreement = contractRoot.appendingPathComponent("agreement.md")
        let agreementBytes = Data("# Working agreement\n\nUser sets goals.\n".utf8)
        try? agreementBytes.write(to: agreement)
        let runnable = contractRoot.appendingPathComponent("agreement.command")
        try? Data("#!/bin/sh\necho no\n".utf8).write(to: runnable)

        let contract = ContractWindow()
        let opener = RecordingContractOpener()
        contract.opener = opener
        var stored: String??
        var acceptSelection = true
        contract.onSelect = { path in
            guard acceptSelection else { return false }
            stored = .some(path)
            return true
        }

        // Settings is where it is reached from, and it says when nothing is chosen.
        panel.settings.orchestrationContractPath = nil
        let contractMenu = panel.debugSettingsMenu()
        check("settings offer the orchestration contract, and say none is chosen",
              contractMenu.items.contains { $0.title == "Orchestration contract… (none chosen)" })
        var opened = 0
        panel.onShowContract = { opened += 1 }
        contractMenu.items.first { $0.title.hasPrefix("Orchestration contract") }
            .map { NSApp.sendAction($0.action!, to: $0.target, from: $0) }
        check("choosing it opens the window and nothing else", opened == 1)

        contract.debugPrepare(selection: nil)
        check("with nothing chosen it says so, and offers nothing to open or clear",
              contract.debugHeadline == "No contract selected"
              && !contract.debugOpenEnabled && !contract.debugClearEnabled)

        // Choosing: through an injected chooser, so no panel is ever presented here.
        contract.chooser = { agreement.path }
        contract.chooseFile()
        check("choosing a document stores the path and reports it as readable",
              stored == .some(agreement.path) && contract.debugHeadline == "Contract selected and readable")
        check("and selecting it did not open it", opener.opens.isEmpty)
        check("the detail line carries size and revision, so a change can be noticed",
              contract.debugDetail.contains("bytes") && contract.debugDetail.contains("revision"))
        check("the document was not touched by any of that",
              (try? Data(contentsOf: agreement)) == agreementBytes)

        // Cancelling changes nothing at all.
        contract.chooser = { nil }
        let beforeCancel = contract.debugSelection
        contract.chooseFile()
        check("cancelling the chooser changes nothing",
              contract.debugSelection == beforeCancel && contract.debugStatus == "Nothing was changed.")

        // Opening: only on an explicit press, and only through a text editor.
        contract.openForEditing()
        check("opening is explicit, and goes to a text editor rather than a file association",
              opener.opens == [canonicalPath(agreement.path)])
        check("and a successful open is reported only after the system says so",
              contract.debugStatus.contains("Opened in a text editor"))

        // A launch that fails must not read as one that worked.
        opener.outcome = "It could not be opened: the editor is not available"
        contract.openForEditing()
        check("a failed open says so rather than claiming success",
              contract.debugStatus.contains("could not be opened"))

        // While the system is still deciding, the window says what is actually true.
        opener.outcome = nil
        opener.deferAnswer = true
        contract.openForEditing()
        check("an open in flight is described as opening, not as opened",
              contract.debugStatus.hasPrefix("Opening ") && contract.debugStatus.hasSuffix("…"))
        let staleTarget = contract.debugSelection
        contract.debugPrepare(selection: runnable.path)      // the user moves on to another document
        opener.deliverLateAnswer()
        check("a late answer about a document no longer selected is ignored",
              !contract.debugStatus.contains("Opened in a text editor")
              && staleTarget != contract.debugSelection)
        // The same rule for the titlebar close: a native close must invalidate an open in flight,
        // or reopening the same document lets a stale "Opened" land on a fresh window.
        contract.debugPrepare(selection: agreement.path)
        contract.openForEditing()
        check("an open is in flight before the window is closed natively",
              contract.debugStatus.hasPrefix("Opening "))
        contract.debugNativeClose()
        contract.debugPrepare(selection: agreement.path)      // reopened on the same selection
        opener.deliverLateAnswer()
        check("an answer that arrives after a native close is ignored",
              !contract.debugStatus.contains("Opened in a text editor"))
        opener.deferAnswer = false
        contract.debugPrepare(selection: agreement.path)

        // A file that could run is refused, whatever a chooser would have allowed.
        contract.chooser = { runnable.path }
        contract.chooseFile()
        check("a runnable file is stored but refused as a document",
              contract.debugHeadline == "Selected — but that type is not supported"
              && !contract.debugOpenEnabled)
        let opensBeforeRunnable = opener.opens.count
        contract.openForEditing()
        check("and pressing open on it launches nothing",
              opener.opens.count == opensBeforeRunnable)

        // A missing file stays selected, and says why.
        let vanished = contractRoot.appendingPathComponent("gone.md")
        contract.debugPrepare(selection: vanished.path)
        check("a missing document stays selected with a clear missing state",
              contract.debugHeadline == "Selected — but the file is missing"
              && contract.debugSelection == vanished.path && !contract.debugOpenEnabled)

        // A pasted path is held to the same rules as a chosen one.
        contract.debugType("https://example.com/agreement.md")
        contract.useTypedPath()
        check("a pasted network location is refused as a document",
              contract.debugHeadline == "Selected — but that type is not supported")
        contract.debugType("agreement.md")
        contract.useTypedPath()
        check("a pasted relative path is refused, so a selection cannot mean two different files",
              contract.debugHeadline == "Selected — but that type is not supported"
              && contract.debugDetail.contains("relative"))
        contract.debugType(agreement.path)
        contract.useTypedPath()
        check("a pasted local path works exactly like a chosen one",
              contract.debugHeadline == "Contract selected and readable")

        // A write that fails must not look like one that worked.
        acceptSelection = false
        contract.debugType(agreement.path)
        contract.useTypedPath()
        check("a selection that could not be saved says so rather than pretending",
              contract.debugStatus.contains("could not be saved"))
        acceptSelection = true

        // Clearing forgets the selection and deletes nothing.
        contract.clearSelection()
        check("clearing forgets the selection", stored == .some(nil) && contract.debugSelection == nil)
        check("and the document is still there",
              FileManager.default.fileExists(atPath: agreement.path))
        check("reveal never opens anything", opener.reveals.isEmpty)
        check("and nothing was ever launched except by an explicit open",
              opener.opens.allSatisfy { $0 == canonicalPath(agreement.path) })

        // A setting that does not save must not look saved.
        acceptChange = false
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        let storedSound = panel.settings.soundEnabled
        _ = panel.debugClickPanelButton(labelledWith: "Sound is on")
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        check("a setting that failed to save says so rather than pretending",
              panel.debugTextValues.contains { $0.contains("could not be saved") })
        check("and the control still shows what is actually stored",
              panel.settings.soundEnabled == storedSound)
        acceptChange = true
        panel.onSettingChange = nil

        // MARK: Linking a Ghostty tab

        // MARK: Two adapters, one gate

        print("Script scheduling")
        // The real `GhosttyAdapter`, twice, with its script executor injected. No AppleScript is
        // compiled, no Apple event is sent, and the running-Ghostty probe is answered by the check
        // rather than by the machine — so this says nothing about, and does nothing to, the real
        // application.
        let stall = DispatchSemaphore(value: 0)
        let blockingExecutor = RecordingExecutor(hold: stall)
        let secondExecutor = RecordingExecutor()
        let firstAdapter = GhosttyAdapter(timeout: 0.6, executor: blockingExecutor, runningProbe: { true })
        let secondAdapter = GhosttyAdapter(timeout: 0.5, executor: secondExecutor, runningProbe: { true })

        // Written on another thread and read here, so it goes through a lock rather than a bare var.
        let firstFailure = FailureBox()
        DispatchQueue.global().async {
            if case .failure(let failure) = firstAdapter.readFocusedTerminalID() { firstFailure.value = failure }
        }
        check("the first adapter's script is genuinely running", blockingExecutor.waitUntilRunning())

        let secondFocus = secondAdapter.focus(terminalID: "term-1")
        check("a second adapter is refused while the first is stuck, not queued behind it",
              { if case .failure(let failure) = secondFocus { return failure == .busy }; return false }())
        check("and its focus was never sent", secondExecutor.sources.isEmpty)

        Thread.sleep(forTimeInterval: 0.8)          // both deadlines pass while the first is stuck
        check("clicking again during the stall is refused the same way",
              { if case .failure(let f) = secondAdapter.focus(terminalID: "term-1") { return f == .busy }
                return false }())
        stall.signal()                               // the stuck script finally returns
        Thread.sleep(forTimeInterval: 0.4)
        check("the focus is STILL never sent — no stale navigation can arrive late",
              secondExecutor.sources.isEmpty)
        check("the first caller was told it timed out", firstFailure.value == .timedOut)
        check("and every script carried the Apple event's own timeout",
              blockingExecutor.sources.allSatisfy { $0.hasPrefix("with timeout of") })

        print("Pairing")
        let mock = MockGhostty()
        let pairingWindow = PairingWindow.synchronous(ghostty: mock)
        var confirmed: [TerminalPairing] = []
        var unlinked: [String] = []
        pairingWindow.onConfirm = { confirmed.append($0); return true }
        pairingWindow.onUnlink = { unlinked.append($0); return true }

        var ghosttyIdentity = items[0].identity
        ghosttyIdentity.tty = "/dev/ttys004"
        pairingWindow.show(identity: ghosttyIdentity, existing: nil)

        check("the window names the session it would link",
              pairingWindow.debugSessionDetail.contains(ghosttyIdentity.sessionID))
        check("and shows the tty, which is the user's own mental model",
              pairingWindow.debugSessionDetail.contains("/dev/ttys004"))
        check("it starts with nothing linked and nothing read",
              pairingWindow.debugExistingText.contains("No Ghostty tab is linked")
              && !pairingWindow.debugConfirmEnabled)
        check("it explains that YOU select the tab, and that nothing is typed",
              PairingWindow.instructions.contains("click the tab")
              && PairingWindow.instructions.contains("never types into a session"))

        pairingWindow.debugReadSelected()
        check("reading shows Ghostty's own terminal id",
              pairingWindow.debugPreviewText.contains("term-1"))
        check("and the tab and window it belongs to, for recognition",
              pairingWindow.debugPreviewText.contains("tab tab-1") && pairingWindow.debugPreviewText.contains("win-1"))
        check("only then can it be confirmed", pairingWindow.debugConfirmEnabled)
        check("reading focused nothing", mock.focusCalls.isEmpty)

        pairingWindow.debugConfirm()
        check("confirming saves exactly one link", confirmed.count == 1)
        check("pinned to this session and this Claude process",
              confirmed.first?.sessionID == ghosttyIdentity.sessionID
              && confirmed.first?.claudePID == ghosttyIdentity.claudePID)
        check("and to this run of Ghostty", confirmed.first?.terminalAppPID == 900)
        check("with the user recorded as the reason it exists",
              confirmed.first?.provenance == "userConfirmed")
        check("confirming re-read before saving", mock.readSelectedCalls == 2)

        // The tab moves between reading and confirming.
        let movingMock = MockGhostty()
        let movingWindow = PairingWindow.synchronous(ghostty: movingMock)
        var movedConfirms = 0
        movingWindow.onConfirm = { _ in movedConfirms += 1; return true }
        movingWindow.show(identity: ghosttyIdentity, existing: nil)
        movingWindow.debugReadSelected()
        movingMock.selected = .success(TerminalSnapshot(terminalID: "term-2", tabID: "tab-2",
                                                        windowID: "win-1", name: "somewhere else"))
        movingWindow.debugConfirm()
        check("a tab that changed between reading and confirming links nothing", movedConfirms == 0)
        check("and the preview is replaced rather than switched silently",
              movingWindow.debugPreviewText.contains("term-2")
              && movingWindow.debugStatusText.contains("different Ghostty tab is selected now"))

        // Ghostty restarts between reading and confirming.
        let restartMock = MockGhostty()
        let restartWindow = PairingWindow.synchronous(ghostty: restartMock)
        var restartConfirms = 0
        restartWindow.onConfirm = { _ in restartConfirms += 1; return true }
        restartWindow.show(identity: ghosttyIdentity, existing: nil)
        restartWindow.debugReadSelected()
        restartMock.fingerprint = ProcessFingerprint(pid: 901, startedAt: 5000)
        restartWindow.debugConfirm()
        check("a Ghostty that restarted between reading and confirming links nothing", restartConfirms == 0)
        check("and says why", restartWindow.debugStatusText.contains("restarted"))

        // Ghostty refuses to answer at all.
        let deniedMock = MockGhostty()
        deniedMock.selected = .failure(.permissionDenied)
        let deniedWindow = PairingWindow.synchronous(ghostty: deniedMock)
        deniedWindow.show(identity: ghosttyIdentity, existing: nil)
        deniedWindow.debugReadSelected()
        check("a refused Automation request is reported as itself",
              deniedWindow.debugStatusText.contains("permission"))
        check("and nothing can be confirmed from it", !deniedWindow.debugConfirmEnabled)

        // The session is replaced while Automation is thinking. Claude Code reuses a session id on
        // resume, so "same id" is not "same session" — the link would be pinned to a process that
        // no longer exists.
        let replacedWindow = PairingWindow.synchronous(ghostty: MockGhostty())
        var replacedSaves = 0
        replacedWindow.onConfirm = { _ in replacedSaves += 1; return true }
        var replacement = ghosttyIdentity
        replacement.claudePID = 5150                       // a different Claude, same session id
        replacedWindow.currentIdentity = { _ in replacement }
        replacedWindow.show(identity: ghosttyIdentity, existing: nil)
        replacedWindow.debugReadSelected()
        replacedWindow.debugConfirm()
        check("a session replaced during the read links nothing", replacedSaves == 0)
        check("and says why, rather than silently pinning the old process",
              replacedWindow.debugStatusText.contains("replaced by a new Claude process"))

        let untrackedWindow = PairingWindow.synchronous(ghostty: MockGhostty())
        var untrackedSaves = 0
        untrackedWindow.onConfirm = { _ in untrackedSaves += 1; return true }
        untrackedWindow.currentIdentity = { _ in nil }      // the engine no longer holds it
        untrackedWindow.show(identity: ghosttyIdentity, existing: nil)
        untrackedWindow.debugReadSelected()
        untrackedWindow.debugConfirm()
        check("a session the engine has dropped links nothing", untrackedSaves == 0)

        // Ghostty restarts *during* the read. The tab id then comes from a different run than the
        // fingerprint taken before it, and a link pinned across that boundary points nowhere.
        let restartingRead = ScriptedGhostty(fingerprints: [
            ProcessFingerprint(pid: 900, startedAt: 1000),
            ProcessFingerprint(pid: 931, startedAt: 9999),
        ])
        let midReadWindow = PairingWindow.synchronous(ghostty: restartingRead)
        var midReadSaves = 0
        midReadWindow.onConfirm = { _ in midReadSaves += 1; return true }
        midReadWindow.show(identity: ghosttyIdentity, existing: nil)
        midReadWindow.debugReadSelected()
        check("a Ghostty that restarted during the read cannot be confirmed from",
              !midReadWindow.debugConfirmEnabled)
        check("and the window says that plainly",
              midReadWindow.debugStatusText.contains("could not be identified"))
        midReadWindow.debugConfirm()
        check("confirming anyway still links nothing", midReadSaves == 0)

        // The red window button, pressed while a confirm is in flight.
        var closingWindow: PairingWindow?
        let closeDuringConfirm = PairingWindow(
            ghostty: MockGhostty(),
            liveness: StubLiveness(),
            runOffMain: { $0() },
            runOnMain: { work in
                // macOS closes the window between the Automation call and its result.
                closingWindow?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
                work()
            })
        closingWindow = closeDuringConfirm
        var closedSaves = 0
        closeDuringConfirm.onConfirm = { _ in closedSaves += 1; return true }
        closeDuringConfirm.show(identity: ghosttyIdentity, existing: nil)
        closeDuringConfirm.debugReadSelected()
        closeDuringConfirm.debugConfirm()
        check("closing the window by its own title bar drops a confirm still in flight",
              closedSaves == 0)

        // The control for that: identical window, nothing closed, and it does save. Without this,
        // the check above could pass because the confirm never got that far.
        let notClosed = PairingWindow(ghostty: MockGhostty(), liveness: StubLiveness(),
                                      runOffMain: { $0() }, runOnMain: { $0() })
        var notClosedSaves = 0
        notClosed.onConfirm = { _ in notClosedSaves += 1; return true }
        notClosed.show(identity: ghosttyIdentity, existing: nil)
        notClosed.debugReadSelected()
        notClosed.debugConfirm()
        check("while the same window, left open, saves normally", notClosedSaves == 1)
        notClosed.close()

        // And the window is left usable, not stuck.
        let reusable = PairingWindow.synchronous(ghostty: MockGhostty())
        var reusedSaves = 0
        reusable.onConfirm = { _ in reusedSaves += 1; return true }
        reusable.show(identity: ghosttyIdentity, existing: nil)
        reusable.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        reusable.show(identity: ghosttyIdentity, existing: nil)
        reusable.debugReadSelected()
        reusable.debugConfirm()
        check("and reopening it afterwards works normally", reusedSaves == 1)
        replacedWindow.close(); untrackedWindow.close(); midReadWindow.close()
        closeDuringConfirm.close(); reusable.close()

        // The write fails. The window must not say "Linked" about something that is not on disk.
        let unsavedWindow = PairingWindow.synchronous(ghostty: MockGhostty())
        var refusedSaves = 0
        unsavedWindow.onConfirm = { _ in refusedSaves += 1; return false }
        unsavedWindow.show(identity: ghosttyIdentity, existing: nil)
        unsavedWindow.debugReadSelected()
        unsavedWindow.debugConfirm()
        check("a link that could not be saved is reported as not saved", refusedSaves == 1)
        check("and the window never claims it was linked",
              !unsavedWindow.debugStatusText.contains("Linked")
              && unsavedWindow.debugStatusText.lowercased().contains("not"))

        let unremovableWindow = PairingWindow.synchronous(ghostty: MockGhostty())
        unremovableWindow.onUnlink = { _ in false }
        unremovableWindow.show(identity: ghosttyIdentity, existing: confirmed.first)
        unremovableWindow.debugUnlink()
        check("and a link that could not be removed still says it is linked",
              unremovableWindow.debugExistingText.contains("term-1"))
        unsavedWindow.close()
        unremovableWindow.close()

        // An existing link can be seen and removed.
        let linkedWindow = PairingWindow.synchronous(ghostty: MockGhostty())
        var removed: [String] = []
        linkedWindow.onUnlink = { removed.append($0); return true }
        linkedWindow.show(identity: ghosttyIdentity, existing: confirmed.first)
        check("an existing link is described, with when you confirmed it",
              linkedWindow.debugExistingText.contains("term-1")
              && linkedWindow.debugExistingText.contains("confirmed by you"))
        linkedWindow.debugUnlink()
        check("and it can be removed", removed == [ghosttyIdentity.sessionID])
        check("removing says what happens next",
              linkedWindow.debugStatusText.contains("you pick the tab"))

        pairingWindow.close()
        movingWindow.close()
        restartWindow.close()
        deniedWindow.close()
        linkedWindow.close()

        // Details offers it, and describes an existing link.
        panel.onLinkTerminal = { _ in }
        panel.pairingLookup = { _ in confirmed.first }
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        // Linking is a Ghostty-only offer, so the checks name that row rather than assuming the
        // sort put it first.
        let ghosttyRow = panel.debugRowAccessibilityLabels
            .firstIndex { $0.hasPrefix(SessionNameStyle.humanised("agent-attention")) } ?? 0
        let pairMenu = panel.debugRowMenu(index: ghosttyRow)?.items.map(\.title) ?? []
        check("the ⋯ menu offers to change or remove the link once one exists",
              pairMenu.contains("Change or remove linked tab…"))
        check("and Details says which tab is linked",
              (panel.debugDetailsMenu(rowIndex: ghosttyRow)?.items.map(\.title) ?? [])
                  .contains { $0.hasPrefix("linked   Ghostty terminal term-1") })
        check("a linked row says a click will go to that tab",
              panel.debugRowTooltips[ghosttyRow].contains("Open the Ghostty tab you linked"))

        panel.pairingLookup = { _ in nil }
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        check("and offers to link one when there is none",
              (panel.debugRowMenu(index: ghosttyRow)?.items.map(\.title) ?? []).contains("Link Ghostty tab…"))
        check("an unlinked Ghostty row opens the conversation instead of guessing a tab",
              panel.debugRowTooltips[ghosttyRow].contains("recent conversation"))

        var unlinkedOpens: [String] = []
        panel.onShowContext = { unlinkedOpens.append($0.sessionID) }
        panel.debugClickRow(index: ghosttyRow)
        check("clicking it shows that session's conversation, where linking is offered",
              unlinkedOpens.count == 1)
        check("and nothing was focused, opened or typed by that click", activated == nil && openedSession == nil)
        panel.onShowContext = nil
        panel.onLinkTerminal = nil

        // MARK: Escape

        print("Escape closes what is open")
        // Driven through Cocoa's own key-equivalent path with a synthetic event delivered to this
        // app's own window. Nothing is posted to the system and no other application can see it.
        var escapeOpens: [String] = []
        let escapeContext = SessionContextWindow.synchronous(query: { _ in
            SessionContextAnswer(sessionID: "sess-escape", identity: .verifiedLive, process: "alive",
                                 attention: .init(known: true, certainty: "waiting", kind: "approval",
                                                  reason: "Permission needed: Bash", waitingSeconds: 30,
                                                  occurrences: 1, snoozed: false, queueIsFresh: true,
                                                  appIsRunning: true, queueAgeSeconds: 1,
                                                  unprocessedEvents: 0, caveats: []),
                                 context: nil, generatedAt: now)
        })
        var escapeReply: ((ContextOpenResult) -> Void)?
        escapeContext.linkStatus = { _ in true }
        escapeContext.onOpenSession = { sessionID, reply in escapeOpens.append(sessionID); escapeReply = reply }
        escapeContext.show(identity: liveIdentity, attention: items.first)
        check("the conversation window is open to begin with", escapeContext.debugIsVisible)

        // Return still belongs to the default action.
        check("Return still presses Open session",
              escapeContext.debugSendReturn() && escapeOpens == ["sess-open-check"])

        check("Escape is consumed by the window it was sent to", escapeContext.debugSendEscape())
        check("and closes it", !escapeContext.debugIsVisible)
        escapeReply?(.landed("a result from before the escape"))
        check("a navigation still in flight is abandoned, not applied",
              !escapeContext.debugNavigationLine.contains("before the escape"))
        check("and nothing about the queue changed",
              snoozeCount == 0 && dismissCount == 0 && dismissAllCount == 0)
        escapeContext.show(identity: liveIdentity, attention: items.first)
        check("the window opens again afterwards, unharmed", escapeContext.debugIsVisible)
        escapeContext.close()

        // The linking window: Escape is a cancel. Nothing unconfirmed may be saved by leaving.
        let escapePairing = PairingWindow.synchronous(ghostty: MockGhostty())
        var escapeSaves = 0
        escapePairing.onConfirm = { _ in escapeSaves += 1; return true }
        escapePairing.show(identity: ghosttyIdentity, existing: nil)
        escapePairing.debugReadSelected()
        check("a tab has been read and could be confirmed", escapePairing.debugConfirmEnabled)
        check("Escape closes the linking window", escapePairing.debugSendEscape() && !escapePairing.isVisible)
        check("and saves nothing that was not confirmed", escapeSaves == 0)
        escapePairing.debugConfirm()
        check("a confirm arriving after the escape is ignored too", escapeSaves == 0)

        // One Escape, one window. The event is consumed where it lands.
        let secondWindow = PairingWindow.synchronous(ghostty: MockGhostty())
        secondWindow.show(identity: ghosttyIdentity, existing: nil)
        escapePairing.show(identity: ghosttyIdentity, existing: nil)
        _ = escapePairing.debugSendEscape()
        check("closing one window on Escape leaves the other open",
              !escapePairing.isVisible && secondWindow.isVisible)
        secondWindow.close()

        check("the panel is not pretended to receive Escape while it can never be key",
              !panel.debugWindowCanBecomeKey)

        // MARK: The chain icon

        print("Chain icon")
        // Three states, read from disk and from the session record — no Automation call is made to
        // draw a row, so none of this depends on Ghostty answering.
        var chainLinks: [String] = []
        panel.onLinkTerminal = { chainLinks.append($0.sessionID) }
        let ghosttySession = sessions.first { TerminalTarget.normalizedTermProgram($0.identity) == "ghostty" }!
        let matchingLink = TerminalPairing(
            sessionID: ghosttySession.identity.sessionID,
            claudePID: ghosttySession.identity.claudePID ?? 0,
            claudePIDStartedAt: ghosttySession.identity.claudePIDStartedAt ?? 0,
            tty: nil, terminalAppBundleID: GhosttyAdapter.bundleIdentifier,
            terminalAppPID: 900, terminalAppStartedAt: 1000,
            terminalID: "term-chain", tabID: "tab-1", windowID: "win-1",
            terminalName: "own-capital", pairedAt: now)
        var supersededLink = matchingLink
        supersededLink.claudePID = 9191            // a different Claude process entirely

        func chainRow(_ pairing: TerminalPairing?) -> (button: ClosureButton, index: Int)? {
            panel.pairingLookup = { sessionID in
                sessionID == ghosttySession.identity.sessionID ? pairing : nil
            }
            panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4,
                         now: now, anchor: bubble.frame)
            let name = SessionNameStyle.humanised(ghosttySession.identity.projectName)
            guard let index = panel.debugRowAccessibilityLabels.firstIndex(where: { $0.hasPrefix(name) }),
                  let button = panel.debugChainButton(index: index) else { return nil }
            return (button, index)
        }

        if let (unlinked, _) = chainRow(nil) {
            check("an unlinked session shows a quiet chain",
                  unlinked.image?.name() == nil || unlinked.contentTintColor == AttentionPanelController.chainColour(.none))
            check("and says plainly that nothing is linked",
                  (unlinked.toolTip ?? "").contains("No Ghostty tab is linked"))
            check("with the same thing said to VoiceOver",
                  (unlinked.accessibilityLabel() ?? "").contains("no Ghostty tab linked"))
        } else {
            check("an unlinked session has a chain to check", false)
        }

        if let (saved, index) = chainRow(matchingLink) {
            check("a saved link is drawn differently from no link",
                  saved.contentTintColor == AttentionPanelController.chainColour(.saved)
                  && saved.contentTintColor != AttentionPanelController.chainColour(.none))
            check("and the wording never claims the tab was verified",
                  (saved.toolTip ?? "").contains("because you said so")
                  && (saved.toolTip ?? "").contains("only known when opening it lands"))
            check("VoiceOver hears the same caveat",
                  (saved.accessibilityLabel() ?? "").contains("not re-checked"))

            // Clicking it goes to the pairing workflow for this exact session — and does nothing else.
            let attentionBefore = panel.debugTextValues
            saved.handler?()
            check("clicking the chain routes that exact session to linking",
                  chainLinks == [ghosttySession.identity.sessionID])
            check("and changes no notification: nothing snoozed, dismissed or opened",
                  snoozeCount == 0 && dismissCount == 0 && dismissAllCount == 0
                  && activated == nil && openedSession == nil)
            check("and the queue on screen is untouched", panel.debugTextValues == attentionBefore)

            // The row's own click must not fire from a press on the icon: an enabled control keeps
            // its own hit, which is the rule the card hit-testing already follows.
            check("the chain is its own hit target, not part of the row",
                  ClickableView.isInteractive(saved) && !ClickableView.isDecoration(saved))
            check("and the row's ⋯ menu still works beside it",
                  (panel.debugRowMenu(index: index)?.items.map(\.title) ?? []).contains("Recent conversation…"))
        } else {
            check("a linked session has a chain to check", false)
        }

        if let (stale, _) = chainRow(supersededLink) {
            check("a link naming a different Claude process is shown as needing attention",
                  stale.contentTintColor == AttentionPanelController.chainColour(.stale))
            check("and says why, without having asked Ghostty anything",
                  (stale.toolTip ?? "").contains("different Claude process"))
            check("VoiceOver hears that too",
                  (stale.accessibilityLabel() ?? "").contains("no longer matches"))
        } else {
            check("a stale link has a chain to check", false)
        }

        // The state rule itself, at the boundary.
        check("a session whose own process is unidentified is not called stale", {
            var anonymous = ghosttySession.identity
            anonymous.claudePID = nil
            anonymous.claudePIDStartedAt = nil
            return SessionLinkState.of(pairing: matchingLink, identity: anonymous) == .saved
        }())
        check("a start time a second apart is still the same process", {
            var drifted = ghosttySession.identity
            drifted.claudePIDStartedAt = (ghosttySession.identity.claudePIDStartedAt ?? 0) + 1
            return SessionLinkState.of(pairing: matchingLink, identity: drifted) == .saved
        }())
        check("and hours apart is not", {
            var reused = ghosttySession.identity
            reused.claudePIDStartedAt = (ghosttySession.identity.claudePIDStartedAt ?? 0) + 7200
            return SessionLinkState.of(pairing: matchingLink, identity: reused) == .stale
        }())

        // Room: the icon must not squeeze the name or the branch into a truncation.
        _ = chainRow(matchingLink)
        check("adding the chain clipped nothing", panel.debugClippedLabels.isEmpty)
        check("and the branch line is still shown in full",
              panel.debugTextValues.contains { $0.hasPrefix("cs/alpha") })

        panel.onLinkTerminal = nil
        panel.pairingLookup = { _ in nil }
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)

        // MARK: Navigating to a linked tab

        print("Linked navigation")
        var linkedIdentity = ghosttyIdentity
        linkedIdentity.termProgram = "ghostty"
        linkedIdentity.terminalAppPath = "/Applications/Ghostty.app"
        let link = TerminalPairing(
            sessionID: linkedIdentity.sessionID,
            claudePID: linkedIdentity.claudePID ?? 0,
            claudePIDStartedAt: linkedIdentity.claudePIDStartedAt ?? 0,
            tty: linkedIdentity.tty,
            terminalAppBundleID: GhosttyAdapter.bundleIdentifier,
            terminalAppPID: 900, terminalAppStartedAt: 1000,
            terminalID: "term-1", tabID: "tab-1", windowID: "win-1",
            terminalName: "red645-own-capital", pairedAt: now)

        // Ghostty is not actually running here, so activation must refuse — which is exactly what
        // it should do. What is being checked is the *decision*, not a live focus.
        // NOTHING here may touch a real application. `InertTerminalApps` answers "yes, it is
        // running" and records the request instead of raising anyone's actual window — the earlier
        // version of this check called `NSRunningApplication.activate()` on whatever Ghostty was
        // really running on this machine.
        let inertApps = InertTerminalApps()
        let happy = MockGhostty()
        let happyOutcome = TerminalActivator.perform(linkedIdentity, pairing: link, ghostty: happy, liveness: StubLiveness(), apps: inertApps)
        check("a valid link focuses that exact terminal id, and nothing else",
              happy.focusCalls == ["term-1"])
        check("and the outcome is judged on what actually happened, not on the request",
              happyOutcome.level == .exactTab)

        let restarted = MockGhostty(fingerprint: ProcessFingerprint(pid: 999, startedAt: 7777))
        let restartedOutcome = TerminalActivator.perform(linkedIdentity, pairing: link, ghostty: restarted, liveness: StubLiveness(), apps: inertApps)
        check("a relaunched Ghostty refuses rather than focusing something else",
              restarted.focusCalls.isEmpty && restartedOutcome.level == .failed)
        check("and tells the user how to put it right",
              restartedOutcome.message.contains("Link Ghostty tab"))

        let closed = MockGhostty(existing: [])
        let closedOutcome = TerminalActivator.perform(linkedIdentity, pairing: link, ghostty: closed, liveness: StubLiveness(), apps: inertApps)
        check("a closed tab refuses rather than falling back to another one",
              closed.focusCalls.isEmpty && closedOutcome.level == .failed)
        check("and says the tab is gone", closedOutcome.message.contains("no longer exists"))

        let gone = MockGhostty(fingerprint: nil)
        let goneOutcome = TerminalActivator.perform(linkedIdentity, pairing: link, ghostty: gone, liveness: StubLiveness(), apps: inertApps)
        check("Ghostty not running refuses, and never starts it",
              gone.focusCalls.isEmpty && goneOutcome.level == .failed)

        let refused = MockGhostty()
        refused.existsResult = .failure(.permissionDenied)
        let refusedOutcome = TerminalActivator.perform(linkedIdentity, pairing: link, ghostty: refused, liveness: StubLiveness(), apps: inertApps)
        check("a refused Automation request is not treated as permission to guess",
              refused.focusCalls.isEmpty && refusedOutcome.level == .failed)

        let wrongTab = MockGhostty()
        wrongTab.focusedResult = .success("term-9")
        let wrongOutcome = TerminalActivator.perform(linkedIdentity, pairing: link, ghostty: wrongTab, liveness: StubLiveness(), apps: inertApps)
        check("focus is READ BACK: landing on a different terminal is not success",
              wrongOutcome.level != .exactTab)

        let unverifiable = MockGhostty()
        unverifiable.focusedResult = .failure(.noSelection)
        let unverifiableOutcome = TerminalActivator.perform(linkedIdentity, pairing: link, ghostty: unverifiable, liveness: StubLiveness(), apps: inertApps)
        check("and a focus that cannot be confirmed is not called exact",
              unverifiableOutcome.level != .exactTab)

        let staleSession = MockGhostty()
        var movedSession = linkedIdentity
        movedSession.claudePID = 4321
        let staleOutcome = TerminalActivator.perform(movedSession, pairing: link, ghostty: staleSession, liveness: StubLiveness(), apps: inertApps)
        check("a link made for a different Claude process routes nowhere",
              staleSession.focusCalls.isEmpty && staleOutcome.level == .failed)

        // A linked tab is a transaction: it lands and is verified, or it fails. There is no
        // "well, Ghostty is in front now" consolation prize, because that leaves the user looking
        // at the wrong tab believing they arrived.
        let refusing = MockGhostty()
        refusing.focusResult = .failure(.terminalMissing)
        let unusedApps = InertTerminalApps()
        let refusedFocus = TerminalActivator.perform(linkedIdentity, pairing: link,
                                                     ghostty: refusing, liveness: StubLiveness(),
                                                     apps: unusedApps)
        check("a focus that failed is a failure, full stop", refusedFocus.level == .failed)
        check("and nothing was brought forward instead", unusedApps.activateCalls == 0)
        check("the reason is the terminal's own", refusedFocus.message.contains("no longer exists"))

        let wrongTabApps = InertTerminalApps()
        let wrongTarget = MockGhostty()
        wrongTarget.focusedResult = .success("term-9")
        let wrongTargetOutcome = TerminalActivator.perform(linkedIdentity, pairing: link,
                                                           ghostty: wrongTarget, liveness: StubLiveness(),
                                                           apps: wrongTabApps)
        check("landing on a different terminal never falls back to raising the app",
              wrongTargetOutcome.level == .failed && wrongTabApps.activateCalls == 0)

        // The case the previous check missed: raising the app *succeeds* while the frontmost
        // application is still something else. A returned `true` from activate() is a request
        // having been made, not a window being in front.
        let stubborn = MockGhostty()
        stubborn.frontmostPID = 4242
        let claimingApps = InertTerminalApps(running: true, activates: true)
        let stubbornOutcome = TerminalActivator.perform(linkedIdentity, pairing: link,
                                                        ghostty: stubborn, liveness: StubLiveness(),
                                                        apps: claimingApps)
        check("an activation that returns true but leaves another app in front is NOT exact",
              stubbornOutcome.level == .failed)
        check("and it says so rather than claiming a landing",
              stubbornOutcome.message.contains("not the frontmost"))
        check("the raise was attempted, and then checked", claimingApps.activateCalls == 1)

        // And the honest success: the app really does come forward.
        let raisable = MockGhostty()
        raisable.frontmostPID = 4242
        let raisingApps = InertTerminalApps(running: true, activates: true)
        raisingApps.onActivate = { raisable.frontmostPID = 900 }     // the pinned Ghostty is now in front
        let raisedOutcome = TerminalActivator.perform(linkedIdentity, pairing: link,
                                                      ghostty: raisable, liveness: StubLiveness(),
                                                      apps: raisingApps)
        check("a raise that genuinely put the pinned Ghostty in front is exact",
              raisedOutcome.level == .exactTab)
        check("and the tab was re-read after the raise, not before",
              raisable.focusedReadCount >= 2)

        // Ghostty restarts while its window is coming forward.
        let restartingDuringRaise = MockGhostty()
        restartingDuringRaise.frontmostPID = 4242
        let raiseApps = InertTerminalApps(running: true, activates: true)
        raiseApps.onActivate = {
            restartingDuringRaise.frontmostPID = 900
            restartingDuringRaise.fingerprint = ProcessFingerprint(pid: 911, startedAt: 5555)
        }
        let restartedDuringRaise = TerminalActivator.perform(linkedIdentity, pairing: link,
                                                             ghostty: restartingDuringRaise,
                                                             liveness: StubLiveness(), apps: raiseApps)
        check("a Ghostty that restarted while coming forward is not a landing",
              restartedDuringRaise.level == .failed)

        // Wording, which is a correctness question here. Once a focus has been accepted, an Apple
        // event cannot be recalled, so "nothing was focused" would be a claim we cannot make.
        check("a refused focus says nothing was focused, because nothing was",
              refusedFocus.message.hasPrefix("Nothing was focused"))
        check("an unproven landing says it could not be confirmed, not that nothing happened",
              wrongTargetOutcome.message.hasPrefix("Could not confirm the linked tab")
              && stubbornOutcome.message.hasPrefix("Could not confirm the linked tab"))

        let timingOut = MockGhostty()
        timingOut.focusResult = .failure(.timedOut)
        let timeoutApps = InertTerminalApps()
        let timedOutFocus = TerminalActivator.perform(linkedIdentity, pairing: link,
                                                      ghostty: timingOut, liveness: StubLiveness(),
                                                      apps: timeoutApps)
        check("a focus that timed out may still have been delivered, and is worded that way",
              timedOutFocus.message.hasPrefix("Could not confirm the linked tab"))
        check("and it still raises nothing", timeoutApps.activateCalls == 0)

        // Ghostty restarts on the already-frontmost path, where nothing needs raising. The success
        // claim is only ever made against the incarnation the link was pinned to.
        let swapUnderneath = ScriptedGhostty(fingerprints: [
            ProcessFingerprint(pid: 900, startedAt: 1000),      // before the focus
            ProcessFingerprint(pid: 977, startedAt: 4242),      // a different Ghostty, at the end
        ])
        let frontmostApps = InertTerminalApps()
        let swapped = TerminalActivator.perform(linkedIdentity, pairing: link,
                                                ghostty: swapUnderneath, liveness: StubLiveness(),
                                                apps: frontmostApps)
        check("a Ghostty that changed during an already-frontmost navigation is not a landing",
              swapped.level == .failed && swapped.message.contains("Ghostty changed"))
        check("and nothing was raised on that path either", frontmostApps.activateCalls == 0)

        // The session ends during the terminal inspection, before anything is sent.
        let notYetSent = MockGhostty()
        let deadBeforeFocus = StubLiveness()
        deadBeforeFocus.kill(linkedIdentity.claudePID ?? 0)
        let preFlight = TerminalActivator.perform(linkedIdentity, pairing: link,
                                                  ghostty: notYetSent, liveness: deadBeforeFocus,
                                                  apps: InertTerminalApps())
        check("a session that ended before the focus was sent stops it being sent",
              preFlight.level == .failed && notYetSent.focusCalls.isEmpty)

        // Selecting a tab inside Ghostty does not bring Ghostty forward. Two claims, and only the
        // second is what the user asked for.
        let background = MockGhostty()
        background.frontmostPID = 4242            // some other app is in front
        let unraisedApps = InertTerminalApps(running: true, activates: false)
        let backgroundOutcome = TerminalActivator.perform(linkedIdentity, pairing: link,
                                                          ghostty: background, liveness: StubLiveness(),
                                                          apps: unraisedApps)
        check("a tab selected behind another app is not called switched-to",
              backgroundOutcome.level == .failed)
        check("and the reason is stated rather than glossed over",
              backgroundOutcome.message.contains("could not be brought forward"))

        let deadProbe = StubLiveness()
        deadProbe.kill(linkedIdentity.claudePID ?? 0)
        let deadGhostty = MockGhostty()
        let deadOutcome = TerminalActivator.perform(linkedIdentity, pairing: link,
                                                    ghostty: deadGhostty, liveness: deadProbe,
                                                    apps: InertTerminalApps())
        check("a link whose Claude process has since died focuses nothing",
              deadGhostty.focusCalls.isEmpty && deadOutcome.level == .failed)

        check("nothing in any of that typed, opened, closed or quit anything",
              happy.focusCalls.count + restarted.focusCalls.count + closed.focusCalls.count
              + gone.focusCalls.count + refused.focusCalls.count == 1)

        print("Row actions")
        // Every action names its own row. This is the check that a menu built for one session can
        // never act on another one — the failure the per-card buttons made easy to introduce.
        panel.pairingLookup = { _ in nil }
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now, anchor: bubble.frame)
        let actionRows = panel.debugRowAccessibilityLabels
        let snoozeRow = actionRows.firstIndex { $0.contains("Permission needed: Bash") } ?? 0
        let dismissRow = actionRows.firstIndex { $0.contains("Asked you a question") } ?? 1
        let snoozeName = actionRows[snoozeRow].components(separatedBy: ". ").first ?? ""
        let dismissName = actionRows[dismissRow].components(separatedBy: ". ").first ?? ""

        check("snooze fires from its own row", panel.debugClickRowMenuItem(index: snoozeRow, titled: "Snooze this notification"))
        check("dismiss fires from its own row", panel.debugClickRowMenuItem(index: dismissRow, titled: "Dismiss this notification"))
        panel.debugClickPanelButton(titled: "Collapse")
        check("and snooze acted on that row's session, once",
              snoozeCount == 1 && SessionNameStyle.humanised(snoozed ?? "") == snoozeName)
        check("and dismiss acted on its own row's session, once",
              dismissCount == 1 && SessionNameStyle.humanised(dismissed ?? "") == dismissName)
        check("neither touched any other session", snoozed != dismissed && dismissAllCount == 0)
        check("and neither opened a terminal as a side effect", activated == nil && openedSession == nil)
        check("collapse is wired", collapsed)

        // MARK: Many sessions

        print("Many sessions")
        let crowd = manySessions(count: 14)
        panel.render(items: [], sessions: crowd, snoozedCount: 0, maxVisible: 4, now: now, anchor: bubble.frame)
        check("a crowded panel stays inside the screen", visible.contains(panel.debugFrame))
        check("the panel keeps its width with fourteen sessions", panel.debugFrame.width <= 420)
        check("the list is capped so the panel cannot outgrow the screen", panel.debugRowCount == 8)
        check("and the cap is stated rather than silently applied",
              panel.debugTextValues.contains { $0 == "+6 more tracked" })

        // A session past the cap is not merely counted — it has to be reachable, and everything a
        // row offers has to work once you get there.
        let shownFirst = panel.debugRowAccessibilityLabels
        let buried = crowd.first { session in
            !shownFirst.contains { $0.hasPrefix(SessionNameStyle.humanised(session.identity.projectName)) }
        }!
        let buriedName = SessionNameStyle.humanised(buried.identity.projectName)
        check("a session past the cap is genuinely out of the first slice",
              !shownFirst.contains { $0.hasPrefix(buriedName) })

        panel.debugClickPanelButton(titled: "Show all 14 sessions")
        panel.render(items: [], sessions: crowd, snoozedCount: 0, maxVisible: 4, now: now, anchor: bubble.frame)
        check("everything tracked stays reachable", panel.debugRowCount == 14)
        check("expanded, the panel is still on screen", visible.contains(panel.debugFrame))
        check("expanded, the panel still fits its width", panel.debugFrame.width <= 420)

        let buriedRow = panel.debugRowAccessibilityLabels.firstIndex { $0.hasPrefix(buriedName) }
        check("the buried session now has a row of its own", buriedRow != nil)
        if let buriedRow {
            var buriedContext: [String] = []
            panel.onShowContext = { buriedContext.append($0.sessionID) }
            check("its ⋯ menu is there like every other row's",
                  (panel.debugRowMenu(index: buriedRow)?.items.map(\.title) ?? []).contains("Recent conversation…"))
            check("and choosing an action acts on that session, not on the one at the top",
                  panel.debugClickRowMenuItem(index: buriedRow, titled: "Recent conversation…")
                  && buriedContext == [buried.identity.sessionID])
            panel.debugClickRow(index: buriedRow)
            check("clicking the buried row itself reaches the same session",
                  buriedContext.count == 2 && buriedContext.last == buried.identity.sessionID)
            panel.onShowContext = nil
        }
        panel.debugClickPanelButton(titled: "Show fewer")

        // MARK: Empty state

        print("Empty state")
        panel.render(items: [], sessions: sessions, snoozedCount: 0, maxVisible: 4, now: now, anchor: bubble.frame)
        let emptyLabels = panel.debugTextValues
        check("the empty subtitle claims only what it knows",
              emptyLabels.contains { $0.hasPrefix("No confirmed requests") })
        check("and never says nothing is needed, which it cannot know",
              !emptyLabels.contains { $0.contains("No attention needed") || $0.contains("need you") })
        // With one row per session, "nothing is waiting" is not an empty screen: every session is
        // still listed with its own state, which is what replaces the old explanatory empty text.
        check("every session is still listed with its state",
              emptyLabels.contains(SessionNameStyle.humanised("alpha")))
        check("uncertainty is still named rather than folded into the silence",
              emptyLabels.contains { $0.contains("uncertain") }
              && emptyLabels.contains { $0.contains("turn ended · state not confirmed") })
        check("and a session that has never reported says exactly that",
              emptyLabels.contains { $0.contains("awaiting first hook") })
        check("nothing to dismiss means no Dismiss all button", !panel.debugButtonTitles.contains("Dismiss all"))

        // A quiet session is still reachable, and an unlinked Ghostty one goes to its conversation
        // rather than guessing at a tab — the same rule as a row with an open request.
        var quietOpens: [String] = []
        panel.onShowContext = { quietOpens.append($0.sessionID) }
        let quietGhostty = panel.debugRowAccessibilityLabels
            .firstIndex { $0.hasPrefix(SessionNameStyle.humanised("alpha")) } ?? 0
        panel.debugClickRow(index: quietGhostty)
        check("a quiet row is still the way into that session", quietOpens.count == 1)
        check("and it opened that row's session, not another one",
              quietOpens.first == sessions.first { $0.identity.projectName == "alpha" }?.identity.sessionID)
        panel.onShowContext = nil

        panel.render(items: [], sessions: [], snoozedCount: 0, maxVisible: 4, now: now, anchor: bubble.frame)
        check("with no sessions at all it says so", panel.debugTextValues.contains { $0.contains("No Claude Code sessions") })
        check("and says what would make one appear",
              panel.debugTextValues.contains { $0.contains("reports through a hook") })

        // MARK: Only a person opens the panel
        //
        // The real panel and the real bubble, driven through the same presentation rule the app
        // uses. What is asserted is what a user would see: a window on screen, or not.

        print("Presentation")
        panel.hide()
        var presentation = PanelPresentation()

        func applyPresentation() {
            bubble.update(pendingCount: items.count, expanded: presentation.isExpanded)
            if presentation.isExpanded {
                panel.render(items: items, sessions: sessions, snoozedCount: 0, maxVisible: 4,
                             now: now, anchor: bubble.frame)
                panel.show()
            } else {
                panel.hide()
            }
        }

        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        presentation.attentionRaised()
        applyPresentation()
        check("an arriving ask does not put the panel on screen", !panel.debugIsVisible)
        check("but the bubble carries the count", !bubble.badgeIsHidden)
        check("and nothing took focus",
              NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore)

        for _ in 0..<5 { presentation.attentionRaised(); presentation.attentionRepeated() }
        applyPresentation()
        check("a burst of them still does not", !panel.debugIsVisible)

        presentation.snoozeExpired()
        presentation.sessionsDiscovered()
        presentation.restoredPendingItems(count: items.count)
        presentation.sweepRan()
        presentation.backgroundActivityChanged()
        presentation.applicationActivated()
        applyPresentation()
        check("nor a snooze expiring, a scan, a restore, a sweep, a job or an activation",
              !panel.debugIsVisible)

        presentation.userToggled()
        applyPresentation()
        check("clicking the bubble opens it", panel.debugIsVisible)
        check("and it opens without taking focus",
              NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore)

        presentation.attentionRaised()
        applyPresentation()
        check("an ask arriving while it is open leaves it open", panel.debugIsVisible)

        presentation.userToggled()
        applyPresentation()
        check("clicking again closes it", !panel.debugIsVisible)

        // A panel the user opened is theirs; one that opened itself is not — and nothing opens
        // itself any more, so an empty queue simply leaves it closed.
        presentation.userToggled()
        presentation.queueEmptied()
        applyPresentation()
        check("an emptied queue leaves the user's own panel open", panel.debugIsVisible)
        presentation.clickedAway()
        applyPresentation()
        check("clicking away closes it", !panel.debugIsVisible)
        check("and the badge is unchanged by any of that", !bubble.badgeIsHidden)

        panel.hide()

        // MARK: Background jobs, beside the ask rather than instead of it

        print("Background activity")
        var jobbedSessions = sessions
        var busy = SessionState(identity: items[1].identity, activity: .awaitingUser,
                                lastEventAt: now, lastActivityAt: now,
                                episodeID: items[1].episodeID, currentItemID: items[1].id)
        var registry = BackgroundRegistry()
        registry.apply(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started",
                                                 "session_id": items[1].identity.sessionID,
                                                 "task_id": "mon-1", "uuid": "u1",
                                                 "task_type": "monitor"])!,
                       ownedBy: items[1].identity.sessionID, at: now)
        registry.apply(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started",
                                                 "session_id": items[1].identity.sessionID,
                                                 "task_id": "sh-2", "uuid": "u2",
                                                 "task_type": "shell"])!,
                       ownedBy: items[1].identity.sessionID, at: now)
        busy.jobs = registry
        jobbedSessions = jobbedSessions.filter { $0.identity.sessionID != busy.identity.sessionID }
            + [busy]
        panel.render(items: items, sessions: jobbedSessions, snoozedCount: 2, maxVisible: 4,
                     now: now, anchor: bubble.frame)

        check("a session with jobs says so beside its request, not instead of it", {
            let text = panel.debugTextValues
            return text.contains { $0 == items[1].kind.label }
                && text.contains { $0.contains("background jobs") || $0.contains("monitor") }
        }())
        check("the compact line names what is running", {
            AttentionPanelController.backgroundLine(busy, now: now, ttl: 1_800)
                == "2 background jobs, 1 a monitor"
        }())
        check("a monitor on its own reads as a monitor", {
            var only = busy
            var single = BackgroundRegistry()
            single.apply(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started", "session_id": "x",
                                                   "task_id": "m", "uuid": "u",
                                                   "task_type": "monitor"])!,
                         ownedBy: "x", at: now)
            only.jobs = single
            return AttentionPanelController.backgroundLine(only, now: now, ttl: 1_800)
                == "1 monitor running"
        }())
        check("a job nobody has heard from in hours stops being reported as running",
              AttentionPanelController.backgroundLine(busy, now: now.addingTimeInterval(7_200),
                                                      ttl: 1_800) == nil)
        check("each job is listed with its identity, kind, state and age", {
            let lines = AttentionPanelController.jobLines(busy, now: now.addingTimeInterval(120),
                                                          ttl: 1_800)
            return lines.count == 2
                && lines.contains { $0.hasPrefix("mon-1") && $0.contains("monitor")
                                    && $0.contains("running") }
                // `shell` says what kind of thing it is, not how long it lives — so the line
                // falls back to the word the client used rather than claiming a finite job.
                && lines.contains { $0.hasPrefix("sh-2") && $0.contains("shell") }
        }())
        check("the details submenu carries the jobs and says how complete the list is", {
            let index = jobbedSessions.firstIndex { $0.identity.sessionID == busy.identity.sessionID }
            _ = index
            let details = (0..<panel.debugRowCount).compactMap { panel.debugDetailsMenu(rowIndex: $0) }
            return details.contains { menu in
                menu.items.contains { $0.title.contains("coverage") }
                    && menu.items.contains { $0.title.contains("mon-1") }
            }
        }())
        check("and never a command, a prompt or a description", {
            let details = (0..<panel.debugRowCount).compactMap { panel.debugDetailsMenu(rowIndex: $0) }
            return !details.contains { menu in
                menu.items.contains { $0.title.contains("rm ") || $0.title.contains("prompt") }
            }
        }())
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now,
                     anchor: bubble.frame)

        // MARK: Readability — measured, over three backdrops
        //
        // **Fixture evidence, and only that.** These are this app's own views drawn over backdrops
        // this check made up. Nothing here is a picture of the panel floating over anybody's real
        // browser window, and none of it proves what the overlay looks like live.
        //
        // What it does prove is the thing that was actually wrong: the interior of the panel used
        // to take its colour from whatever was behind the window, so contrast depended on the page
        // underneath. Each surface is composited over white, over near-black and over a busy
        // pattern; if the interior pixels are the same in all three, the backdrop cannot reach the
        // text — and the contrast measured against those pixels is the contrast a person gets.

        print("Readability")
        panel.settings = AttentionConfig.default
        panel.flash("", seconds: 0.01)
        panel.render(items: items, sessions: sessions, snoozedCount: 2, maxVisible: 4, now: now,
                     anchor: bubble.frame)
        bubble.update(pendingCount: 3, expanded: false)

        let backdrops = Readability.backdrops()
        guard let panelShot = Readability.snapshot(panel.debugContentView),
              let bubbleShot = Readability.snapshot(bubble.debugContentView) else {
            check("the panel and bubble could be drawn for measurement", false)
            return failures.isEmpty ? 0 : 1
        }

        var panelInteriors: [(String, Readability.Pixel)] = []
        var panelCorners: [(String, Readability.Pixel)] = []
        var bubbleInteriors: [(String, Readability.Pixel)] = []
        var written: [String] = []
        for backdrop in backdrops {
            guard let over = Readability.composite(panelShot, over: backdrop),
                  let bubbleOver = Readability.composite(bubbleShot, over: backdrop) else {
                check("the panel composited over the \(backdrop.name) backdrop", false)
                continue
            }
            // Well inside each surface: clear of the rounded corners, and clear of the glyph and
            // the badge, so what is sampled really is the plate.
            panelInteriors.append((backdrop.name,
                                   Readability.pixel(over, x: over.pixelsWide / 2, y: 4)))
            // The very corner is outside the rounded plate, so it shows the backdrop. Sampling it
            // is how this check proves it really composited something, rather than measuring a
            // surface floating over nothing.
            panelCorners.append((backdrop.name, Readability.pixel(over, x: 0, y: 0)))
            bubbleInteriors.append((backdrop.name,
                                    Readability.pixel(bubbleOver, x: bubbleOver.pixelsWide / 4,
                                                      y: bubbleOver.pixelsHigh / 2)))
            if let folder = readabilityPath.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (name, rep) in [("panel", over), ("bubble", bubbleOver)] {
                    let url = folder.appendingPathComponent("readability-\(name)-\(backdrop.name).png")
                    if let data = rep.representation(using: .png, properties: [:]),
                       (try? data.write(to: url)) != nil {
                        written.append(url.path)
                    }
                }
            }
        }

        check("the panel interior is identical over white, dark and a busy pattern",
              Readability.allAlike(panelInteriors.map(\.1)))
        check("so is the bubble's", Readability.allAlike(bubbleInteriors.map(\.1)))
        if let first = panelInteriors.first {
            print("  panel plate as rendered: \(Readability.describe(first.1))")
        }
        if let first = bubbleInteriors.first {
            print("  bubble as rendered:      \(Readability.describe(first.1))")
        }
        check("the backdrops really are behind the surface — the corner shows each of them", {
            guard panelCorners.count == 3 else { return false }
            let byName = Dictionary(uniqueKeysWithValues: panelCorners)
            print("  corner over white: \(byName["white"].map(Readability.describe) ?? "-")")
            print("  corner over dark:  \(byName["dark"].map(Readability.describe) ?? "-")")
            return (byName["white"]?.red ?? 0) > 0.9 && (byName["dark"]?.red ?? 1) < 0.1
        }())
        check("the panel interior is fully opaque",
              panelInteriors.allSatisfy { $0.1.alpha > 0.99 })
        check("and no longer a translucent material",
              panelInteriors.first.map { !Readability.looksLike($0.1, backdrops[0].name == "white") } ?? false)

        // Contrast, measured against the plate **as rendered**, not against a constant.
        if let plate = panelInteriors.first?.1 {
            for entry in AttentionPanelController.measuredColors {
                let resolved = Readability.components(entry.color)
                let ratio = Contrast.ratio(resolved, (plate.red, plate.green, plate.blue))
                check(String(format: "%@ text is %.1f:1 on the plate (floor %.1f)",
                             entry.name, ratio, entry.floor), ratio >= entry.floor)
            }
        }
        if let disc = bubbleInteriors.first?.1 {
            let badge = Readability.components(BubbleView.badgeColor)
            let glyph = Readability.components(BubbleView.badgeTextColor)
            check(String(format: "the badge is %.1f:1 on the bubble (floor %.1f)",
                         Contrast.ratio(badge, (disc.red, disc.green, disc.blue)), Contrast.controlFloor),
                  Contrast.ratio(badge, (disc.red, disc.green, disc.blue)) >= Contrast.controlFloor)
            check(String(format: "the badge count is %.1f:1 on the badge (floor %.1f)",
                         Contrast.ratio(glyph, badge), Contrast.controlFloor),
                  Contrast.ratio(glyph, badge) >= Contrast.controlFloor)
        }

        // The other half of the fix: a system appearance switch must not move any of this.
        check("every panel colour resolves the same in Light and in Dark", {
            let light = NSAppearance(named: .aqua)!
            let dark = NSAppearance(named: .darkAqua)!
            return AttentionPanelController.measuredColors.allSatisfy { entry in
                var inLight = (0.0, 0.0, 0.0)
                var inDark = (0.0, 0.0, 0.0)
                light.performAsCurrentDrawingAppearance { inLight = Readability.components(entry.color) }
                dark.performAsCurrentDrawingAppearance { inDark = Readability.components(entry.color) }
                return abs(inLight.0 - inDark.0) < 0.01 && abs(inLight.1 - inDark.1) < 0.01
                    && abs(inLight.2 - inDark.2) < 0.01
            }
        }())
        check("and the panel's own appearance is pinned dark, so semantic colours cannot invert",
              panel.debugAppearanceName == NSAppearance.Name.darkAqua)
        check("as is the bubble's", bubble.debugAppearanceName == NSAppearance.Name.darkAqua)
        // The corners stay transparent — that is what makes them round, and is expected.
        check("the corners are still transparent, so the shape survives",
              Readability.pixel(panelShot, x: 0, y: 0).alpha < 0.5)

        if !written.isEmpty {
            print("  fixture composites (not a live overlay capture):")
            written.forEach { print("    \($0)") }
        }

        // MARK: Render export

        if let pngPath {
            print("Render")
            let base = URL(fileURLWithPath: (pngPath as NSString).expandingTildeInPath)
            let folder = base.deletingLastPathComponent()

            // A second fixture for the pairing window, beside the panel one.
            let pairingShot = PairingWindow.synchronous(ghostty: MockGhostty())
            pairingShot.show(identity: ghosttyIdentity, existing: nil)
            pairingShot.debugReadSelected()
            let pairingURL = folder.appendingPathComponent("pairing.png")
            check("the pairing window rendered to \(pairingURL.path)", pairingShot.debugWritePNG(to: pairingURL))
            pairingShot.close()

            // The conversation window, so the new Open session action can be looked at. Its
            // transcript is the same constructed sample used above — no live session, no real file.
            let contextShot = SessionContextWindow.synchronous(query: { _ in
                SessionContextAnswer(sessionID: "sess-open-check", identity: .verifiedLive, process: "alive",
                                     attention: .init(known: true, certainty: "waiting", kind: "approval",
                                                      reason: "Permission needed: Bash", waitingSeconds: 30,
                                                      occurrences: 1, snoozed: false, queueIsFresh: true,
                                                      appIsRunning: true, queueAgeSeconds: 1,
                                                      unprocessedEvents: 0, caveats: []),
                                     context: sampleContext, generatedAt: now)
            })
            contextShot.linkStatus = { _ in true }
            contextShot.onOpenSession = { _, _ in }
            contextShot.onLinkTerminal = { _ in }
            contextShot.show(identity: liveIdentity, attention: items.first)
            let contextURL = folder.appendingPathComponent("context.png")
            check("the conversation window rendered to \(contextURL.path)", contextShot.debugWritePNG(to: contextURL))
            contextShot.close()

            // Every fixture is drawn with a clean status line. A deliberately-failed save from the
            // settings checks above must not read as the app's own state in a picture people will
            // look at without the surrounding output.
            func shot(_ name: String, items: [AttentionItem], sessions: [SessionState],
                      snoozed: Int, url: URL) -> Bool {
                panel.flash("", seconds: 0.01)
                panel.render(items: items, sessions: sessions, snoozedCount: snoozed,
                             maxVisible: 4, now: now, anchor: bubble.frame)
                let ok = panel.debugWritePNG(to: url)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
                check("\(name) rendered to \(url.path) (\(bytes?.intValue ?? 0) bytes)", ok)
                return ok
            }

            // The representative one: the worktrees this is actually used on, each with the branch
            // read from its own directory, and one of each state worth seeing.
            let (realItems, realSessions) = representativeFixture(now: now)
            panel.pairingLookup = { sessionID in
                sessionID == realSessions.first?.identity.sessionID ? confirmed.first : nil
            }
            _ = shot("the representative panel", items: realItems, sessions: realSessions,
                     snoozed: 0, url: base)
            check("the fixture shows recognisable worktree names, not sample identifiers",
                  panel.debugTextValues.contains("RED-658 · Plan vs ledger")
                  && panel.debugTextValues.contains("Client info · T1"))
            check("each one carries the branch read from its directory",
                  panel.debugTextValues.contains("cs/red658-plan-vs-ledger")
                  && panel.debugTextValues.contains("cs/exec-cashflow-truth"))
            check("and the status line is neutral, not a leftover from a check",
                  !panel.debugTextValues.contains { $0.contains("could not be saved") })
            panel.pairingLookup = { _ in nil }

            // One fixture showing all three chain states side by side, so the icons can be judged
            // against each other rather than one at a time.
            panel.onLinkTerminal = { _ in }
            let chainSessions = realSessions
            panel.pairingLookup = { sessionID in
                guard let first = chainSessions.first?.identity.sessionID,
                      let second = chainSessions.dropFirst().first?.identity else { return nil }
                if sessionID == first {
                    return TerminalPairing(sessionID: first, claudePID: chainSessions[0].identity.claudePID ?? 0,
                                           claudePIDStartedAt: chainSessions[0].identity.claudePIDStartedAt ?? 0,
                                           tty: nil, terminalAppBundleID: GhosttyAdapter.bundleIdentifier,
                                           terminalAppPID: 900, terminalAppStartedAt: 1000,
                                           terminalID: "term-linked", tabID: "tab-1", windowID: "win-1",
                                           terminalName: "plan-vs-ledger", pairedAt: now)
                }
                if sessionID == second.sessionID {
                    // Saved against a Claude process this session no longer has: shown as stale,
                    // decided by comparing fingerprints, with nothing asked of Ghostty.
                    return TerminalPairing(sessionID: second.sessionID, claudePID: 9191,
                                           claudePIDStartedAt: 1,
                                           tty: nil, terminalAppBundleID: GhosttyAdapter.bundleIdentifier,
                                           terminalAppPID: 900, terminalAppStartedAt: 1000,
                                           terminalID: "term-old", tabID: "tab-9", windowID: "win-1",
                                           terminalName: "client-info", pairedAt: now)
                }
                return nil
            }
            _ = shot("the three link states", items: realItems, sessions: realSessions, snoozed: 0,
                     url: folder.appendingPathComponent("panel-links.png"))
            panel.onLinkTerminal = nil
            panel.pairingLookup = { _ in nil }

            // Regression fixtures, kept apart so the representative one stays readable.
            _ = shot("the long-name and mixed-state regression",
                     items: items, sessions: sessions, snoozed: 2,
                     url: folder.appendingPathComponent("panel-long-names.png"))
            _ = shot("the crowded-list regression", items: [], sessions: manySessions(count: 14),
                     snoozed: 0, url: folder.appendingPathComponent("panel-crowded.png"))
            // The queue and the session records have to agree, or the picture shows rows saying
            // "needs you" with nothing to point at — an artefact of the fixture, not of the app.
            let errorItems = items.filter { $0.kind == .error }
            let errorSessions = sessions.map { session -> SessionState in
                guard let held = session.currentItemID,
                      !errorItems.contains(where: { $0.id == held }) else { return session }
                var quiet = session
                quiet.currentItemID = nil
                quiet.activity = .awaitingUser
                return quiet
            }
            _ = shot("the failure-and-uncertainty regression",
                     items: errorItems, sessions: errorSessions, snoozed: 0,
                     url: folder.appendingPathComponent("panel-errors.png"))
            panel.flash("", seconds: 0.01)
        }

        // MARK: Menu bar

        print("Menu bar")
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "● \(items.count)"
        check("the status item has a button", statusItem.button != nil)
        check("the status item shows the pending count", statusItem.button?.title == "● 5")
        NSStatusBar.system.removeStatusItem(statusItem)

        check("no self-check ever asked to activate, script or drive a real terminal",
              ActivationSafety.refusals.isEmpty)
        if !ActivationSafety.refusals.isEmpty {
            print("  ! \(ActivationSafety.refusals.joined(separator: ", "))")
        }

        print("Speech")
        check("speech is off unless asked for", SpeechAnnouncer().isEnabled == false)

        panel.hide()
        bubble.hide()
        check("closing the panel hands the cursor back", NSCursor.current == NSCursor.arrow)

        print("")
        if failures.isEmpty {
            print("UI check passed.")
            return 0
        }
        print("UI check FAILED: \(failures.joined(separator: "; "))")
        return 1
    }

    // MARK: - Samples

    private static func sampleItems() -> [AttentionItem] {
        [
            item(kind: .approval, project: "agent-attention", detail: "Permission needed: Bash", age: 90,
                 termProgram: "ghostty", appPath: "/Applications/Ghostty.app"),
            item(kind: .question, project: "wunda-api", detail: "Asked you a question", age: 600,
                 termProgram: "iTerm.app", appPath: "/Applications/iTerm.app", itermID: "w0t0p0:ABC-123"),
            item(kind: .error, project: "redmy-core", detail: "Claude Code stopped with an error",
                 age: 720, termProgram: "Apple_Terminal",
                 appPath: "/System/Applications/Utilities/Terminal.app", tty: "/dev/ttys003"),
            item(kind: .workComplete, project: "docs", detail: "Turn complete", age: 20,
                 termProgram: nil, appPath: nil),   // nothing to raise: must offer the resume command
            item(kind: .idle, project: "scratch", detail: "Idle at the prompt", age: 3600,
                 termProgram: "ghostty", appPath: "/Applications/Ghostty.app"),
        ]
    }

    private static func sampleSessions() -> [SessionState] {
        let now = Date()
        return [
            SessionState(identity: identity(project: "alpha", termProgram: "ghostty", appPath: "/Applications/Ghostty.app",
                                            title: "redmy-e9", titleSource: "derived",
                                            branch: .git(.branch("cs/alpha"), path: "/Users/dev/code/alpha", at: now)),
                         activity: .working, lastEventAt: now, lastActivityAt: now),
            SessionState(identity: identity(project: "beta", termProgram: "ghostty", appPath: "/Applications/Ghostty.app"),
                         activity: .awaitingUser, lastEventAt: now, lastActivityAt: now),
            // Found in the registry, never heard from: the state the label has to be honest about.
            SessionState(identity: identity(project: "gamma", termProgram: "ghostty", appPath: "/Applications/Ghostty.app"),
                         activity: .discovered, lastEventAt: now, lastActivityAt: now,
                         hasHookEvidence: false,
                         discovery: SessionDiscovery(discoveredAt: now, registryStatus: "busy")),
            // A turn that ended without anything confirming how. Not waiting, not quiet.
            SessionState(identity: identity(project: "delta", termProgram: "ghostty", appPath: "/Applications/Ghostty.app"),
                         activity: .unknown, lastEventAt: now, lastActivityAt: now,
                         background: BackgroundEvidence(availability: .unknown, observedAt: now)),
            // A name long enough that truncating it would make it useless, paused on its own work.
            SessionState(identity: identity(project: "wundamental-exec-cashflow-truth-sensitivity-train",
                                            termProgram: "ghostty", appPath: "/Applications/Ghostty.app",
                                            tty: "/dev/ttys009"),
                         activity: .backgroundWaiting, lastEventAt: now, lastActivityAt: now,
                         background: BackgroundEvidence(availability: .reported, running: 1,
                                                        types: ["shell"], observedAt: now)),
        ]
    }

    /// The five worktrees this app is actually used on, with the branch each one is really on.
    ///
    /// A picture is read as "what it looks like", so a fixture full of `alpha`, `beta`, `docs` and
    /// `scratch` teaches nothing about whether the names are recognisable at a glance. These are the
    /// real shapes — a ticket-and-topic worktree, a variant suffix, a plain topic — with one row in
    /// each state worth seeing: asking, asked, finished, working, paused on its own work.
    ///
    /// It is still a **fixture**: constructed records, no live sessions, nothing read from disk.
    private static func representativeFixture(now: Date) -> ([AttentionItem], [SessionState]) {
        func worktree(_ project: String, _ branch: String) -> SessionIdentity {
            identity(project: project, termProgram: "ghostty", appPath: "/Applications/Ghostty.app",
                     branch: .git(.branch(branch), path: "/Users/dev/code/\(project)", at: now))
        }

        let planVsLedger = worktree("red658-plan-vs-ledger", "cs/red658-plan-vs-ledger")
        let clientInfo = worktree("client-info-t1", "cs/client-info-t1")
        let cashflow = worktree("exec-cashflow-truth", "cs/exec-cashflow-truth")
        let ownCapital = worktree("red645-own-capital", "cs/red645-own-capital")
        let sensitivity = worktree("sensitivity-train", "cs/sensitivity-train")

        func item(_ identity: SessionIdentity, _ kind: AttentionKind, _ detail: String,
                  _ age: TimeInterval) -> AttentionItem {
            AttentionItem(sessionID: identity.sessionID, episodeID: "episode-\(identity.sessionID)",
                          kind: kind, source: .explicit, detail: detail,
                          firstSeenAt: now.addingTimeInterval(-age),
                          lastSeenAt: now.addingTimeInterval(-age), identity: identity)
        }

        let items = [
            item(planVsLedger, .approval, "Permission needed: Bash", 70),
            item(clientInfo, .question, "Which client should this run against?", 240),
            item(cashflow, .workComplete, "Turn complete", 30),
        ]
        let sessions = [
            SessionState(identity: planVsLedger, activity: .awaitingUser, lastEventAt: now,
                         lastActivityAt: now, currentItemID: items[0].id),
            SessionState(identity: clientInfo, activity: .awaitingUser, lastEventAt: now,
                         lastActivityAt: now, currentItemID: items[1].id),
            SessionState(identity: cashflow, activity: .awaitingUser, lastEventAt: now,
                         lastActivityAt: now, currentItemID: items[2].id),
            SessionState(identity: ownCapital, activity: .working, lastEventAt: now, lastActivityAt: now),
            SessionState(identity: sensitivity, activity: .backgroundWaiting, lastEventAt: now,
                         lastActivityAt: now,
                         background: BackgroundEvidence(availability: .reported, running: 1,
                                                        types: ["shell"], observedAt: now)),
        ]
        return (items, sessions)
    }

    private static func manySessions(count: Int) -> [SessionState] {
        let now = Date()
        return (0..<count).map { index in
            SessionState(
                identity: identity(project: "project-with-a-fairly-long-worktree-name-\(index)",
                                   termProgram: "ghostty", appPath: "/Applications/Ghostty.app"),
                activity: index.isMultiple(of: 2) ? .working : .awaitingUser,
                lastEventAt: now,
                lastActivityAt: now
            )
        }
    }

    private static func identity(
        project: String,
        termProgram: String?,
        appPath: String?,
        itermID: String? = nil,
        tty: String? = nil,
        title: String? = nil,
        titleSource: String? = nil,
        branch: BranchFact? = nil
    ) -> SessionIdentity {
        SessionIdentity(
            sessionID: UUID().uuidString,
            cwd: "/Users/dev/code/\(project)",
            claudePID: 1234,
            claudePIDStartedAt: 1,
            tty: tty,
            termProgram: termProgram,
            itermSessionID: itermID,
            terminalAppPath: appPath,
            title: title,
            titleSource: titleSource,
            branch: branch
        )
    }

    private static func item(
        kind: AttentionKind,
        project: String,
        detail: String,
        age: TimeInterval,
        source: SignalSource = .explicit,
        termProgram: String?,
        appPath: String?,
        itermID: String? = nil,
        tty: String? = nil
    ) -> AttentionItem {
        let id = identity(project: project, termProgram: termProgram, appPath: appPath, itermID: itermID, tty: tty)
        return AttentionItem(
            sessionID: id.sessionID,
            episodeID: "episode-\(project)",
            kind: kind,
            source: source,
            detail: detail,
            firstSeenAt: Date().addingTimeInterval(-age),
            lastSeenAt: Date(),
            identity: id
        )
    }
}


/// Stands in for `AppDelegate` in the menu check: the same selectors, and a count of how many times
/// Quit was actually invoked. Quitting the real app mid-check would end the check.
/// A Ghostty whose process identity changes between calls, so a restart can be placed exactly
/// where it does damage: in the middle of a read.
final class ScriptedGhostty: GhosttyControlling, @unchecked Sendable {
    private var fingerprints: [ProcessFingerprint?]
    private var index = 0
    var selected: Result<TerminalSnapshot, GhosttyFailure> = .success(
        TerminalSnapshot(terminalID: "term-1", tabID: "tab-1", windowID: "win-1",
                         name: "red645-own-capital", workingDirectory: "/w/red645-own-capital"))

    init(fingerprints: [ProcessFingerprint?]) { self.fingerprints = fingerprints }

    func processIdentity() -> ProcessFingerprint? {
        defer { index += 1 }
        return fingerprints[Swift.min(index, fingerprints.count - 1)]
    }

    func readSelectedTerminal() -> Result<TerminalSnapshot, GhosttyFailure> { selected }
    func terminalExists(id: String) -> Result<Bool, GhosttyFailure> { .success(true) }
    func focus(terminalID: String) -> Result<Void, GhosttyFailure> { .success(()) }
    func readFocusedTerminalID() -> Result<String, GhosttyFailure> { .success("term-1") }
    func frontmostApplicationPID() -> Int32? { fingerprints.first??.pid }
}

/// A lock-guarded slot for a failure produced on another thread.
final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GhosttyFailure?
    var value: GhosttyFailure? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Records what was actually sent, and can be held open. Used by the scheduling checks.
final class RecordingExecutor: ScriptExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var executed: [String] = []
    private let hold: DispatchSemaphore?
    private let entered = DispatchSemaphore(value: 0)

    init(hold: DispatchSemaphore? = nil) { self.hold = hold }

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

    @discardableResult
    func waitUntilRunning(seconds: TimeInterval = 5) -> Bool {
        entered.wait(timeout: .now() + seconds) == .success
    }
}

final class QuitProbe: NSObject {
    private(set) var quits = 0
    private(set) var toggles = 0
    private(set) var reveals = 0

    @objc func menuQuit() { quits += 1 }
    @objc func menuToggleExpansion() { toggles += 1 }
    @objc func menuReveal() { reveals += 1 }
}

/// A player that records instead of sounding. Everything the UI check knows about the chime, it
/// learns from this — nothing in an automated run is allowed to make a noise on someone's machine.
private final class RecordingChimePlayer: ChimeSounding, @unchecked Sendable {
    private(set) var played = 0
    private(set) var last: ChimeSound?
    private(set) var stopped = 0
    func play(_ sound: ChimeSound) { played += 1; last = sound }
    func stop() { stopped += 1 }
}

/// An opener that records instead of launching. Nothing in an automated run may bring an
/// application forward on somebody's machine, least of all by opening a file.
private final class RecordingContractOpener: ContractOpening {
    private(set) var opens: [String] = []
    private(set) var reveals: [String] = []
    /// What the system will "report" — nil for success. Set per case.
    var outcome: String?
    /// Hold the answer instead of giving it, so a late reply can be delivered on purpose.
    var deferAnswer = false
    private var pending: (() -> Void)?

    func openForEditing(_ path: String, completion: @escaping (String?) -> Void) {
        opens.append(path)
        let answer = outcome
        if deferAnswer { pending = { completion(answer) } } else { completion(answer) }
    }

    /// Deliver a held answer now — the late callback a real launch can produce.
    func deliverLateAnswer() { let held = pending; pending = nil; held?() }

    func reveal(_ path: String) { reveals.append(path) }
}

/// `realpath`, matching what the reader reports.
private func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Drawing this app's own surfaces over backdrops it invents, and measuring what comes out.
///
/// Deliberately self-contained: it renders views this process owns into bitmaps and composites
/// them. It captures no screen, sees no other application, and needs no permission — so what it
/// produces is **fixture evidence**, useful for judging contrast and opacity, and not a picture of
/// the panel over anybody's real window.
enum Readability {
    struct Pixel {
        var red: Double, green: Double, blue: Double, alpha: Double
    }

    struct Backdrop {
        let name: String
        let draw: (NSSize) -> Void
    }

    /// White (the case the user reported), near-black, and something busy enough that any leak
    /// through the surface would show up as a pattern rather than a shade.
    static func backdrops() -> [Backdrop] {
        [
            Backdrop(name: "white") { size in
                NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
            },
            Backdrop(name: "dark") { size in
                NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1).setFill()
                NSRect(origin: .zero, size: size).fill()
            },
            Backdrop(name: "busy") { size in
                NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
                let colours: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue,
                                          .systemPurple, .black]
                var index = 0
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        colours[index % colours.count].setFill()
                        NSRect(x: x, y: y, width: 12, height: 12).fill()
                        index += 1
                        x += 12
                    }
                    y += 12
                    index += 1
                }
            },
        ]
    }

    static func snapshot(_ view: NSView?) -> NSBitmapImageRep? {
        guard let view else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The surface drawn over a backdrop, exactly as the compositor would.
    static func composite(_ surface: NSBitmapImageRep, over backdrop: Backdrop) -> NSBitmapImageRep? {
        let size = NSSize(width: surface.pixelsWide, height: surface.pixelsHigh)
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: surface.pixelsWide,
                                            pixelsHigh: surface.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        backdrop.draw(size)
        // Stated rather than assumed: an image rep will happily draw with `copy`, which replaces
        // the backdrop instead of sitting on it — and the composite would then be the surface over
        // nothing while claiming to be the surface over white.
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        surface.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver,
                     fraction: 1.0, respectFlipped: true, hints: nil)
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return canvas
    }

    /// One pixel, in sRGB, inset from the top-left corner in *pixels*.
    static func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Pixel {
        let clampedX = min(max(x, 0), rep.pixelsWide - 1)
        let clampedY = min(max(y, 0), rep.pixelsHigh - 1)
        guard let colour = rep.colorAt(x: clampedX, y: clampedY),
              let srgb = colour.usingColorSpace(.sRGB) else {
            return Pixel(red: 0, green: 0, blue: 0, alpha: 0)
        }
        return Pixel(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                     blue: Double(srgb.blueComponent), alpha: Double(srgb.alphaComponent))
    }

    /// Are these the same colour to within a rounding error? That is the opacity proof: three
    /// different backdrops, one interior.
    static func allAlike(_ pixels: [Pixel]) -> Bool {
        guard let first = pixels.first, pixels.count > 1 else { return false }
        return pixels.allSatisfy {
            abs($0.red - first.red) < 0.012 && abs($0.green - first.green) < 0.012
                && abs($0.blue - first.blue) < 0.012
        }
    }

    /// A surface that had taken on its backdrop would be near-white over white. This is the
    /// symptom the fix is for, stated as a check rather than as a promise.
    static func looksLike(_ pixel: Pixel, _ overWhite: Bool) -> Bool {
        overWhite ? pixel.red > 0.5 : pixel.red < 0.02
    }

    static func describe(_ pixel: Pixel) -> String {
        String(format: "sRGB %.3f, %.3f, %.3f, alpha %.2f",
               pixel.red, pixel.green, pixel.blue, pixel.alpha)
    }

    /// A colour as it actually resolves, in sRGB.
    static func components(_ colour: NSColor) -> (red: Double, green: Double, blue: Double) {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }
}
