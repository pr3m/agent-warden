import AppKit
import AgentAttentionCore

/// The bubble's secondary-click menu.
///
/// The bubble is the only surface that is always on screen, so it has to be able to quit the app
/// without hunting for the menu bar. It is built here rather than inline so that the menu bar item
/// and the bubble cannot drift apart on the one action where drifting would matter: **there is a
/// single constructor for Quit, and both menus call it.** A second termination path is exactly the
/// kind of thing that ends up doing something subtly different.
enum BubbleMenu {
    /// Title of the quit item. Also what a test looks for.
    static var quitTitle: String { "Quit \(AgentAttentionVersion.displayName)" }

    /// The one and only Quit item.
    ///
    /// Ordinary termination: `NSApp.terminate` runs `applicationWillTerminate`, which saves the
    /// queue and clears the presence file. It touches nothing else — not the hooks, not
    /// `settings.json`, not the login item. The login item is `RunAtLoad` with `KeepAlive` off, so
    /// quitting does not respawn the app; it comes back at the next login.
    static func quitItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let quit = NSMenuItem(title: quitTitle, action: action, keyEquivalent: "q")
        quit.target = target
        quit.isEnabled = true
        quit.setAccessibilityLabel("Quit \(AgentAttentionVersion.displayName). "
                                  + "Stops watching your sessions until you start it again.")
        return quit
    }

    struct Actions {
        var toggleSessions: Selector
        var revealDataFolder: Selector
        var quit: Selector
        /// Built by the caller, because it reflects the current configuration.
        var placement: NSMenuItem?
    }

    static func build(
        pendingCount: Int,
        isExpanded: Bool,
        target: AnyObject,
        actions: Actions
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // "No sessions need you" would be a claim; the badge only counts confirmed requests.
        let header = NSMenuItem(
            title: pendingCount == 0
                ? "\(AgentAttentionVersion.displayName) — no confirmed requests"
                : "\(AgentAttentionVersion.displayName) — \(pendingCount) waiting",
            action: nil, keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: isExpanded ? "Hide sessions" : "Show sessions",
                                action: actions.toggleSessions, keyEquivalent: "")
        toggle.target = target
        toggle.isEnabled = true
        menu.addItem(toggle)

        if let placement = actions.placement { menu.addItem(placement) }

        let reveal = NSMenuItem(title: "Reveal data folder", action: actions.revealDataFolder, keyEquivalent: "")
        reveal.target = target
        reveal.isEnabled = true
        menu.addItem(reveal)

        menu.addItem(.separator())
        menu.addItem(quitItem(target: target, action: actions.quit))
        return menu
    }
}
