import AppKit
import AgentAttentionCore

// Agent Attention — a menu-bar-only watcher for concurrent Claude Code sessions.
//
// `--version` and `--paths` answer without starting a UI, so an installer or a smoke test can
// verify the binary without putting anything on screen.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print("\(AgentAttentionVersion.displayName) \(AgentAttentionVersion.string)")
    exit(0)
}

if arguments.contains("--paths") {
    let paths = AppPaths.resolved()
    print("""
    root     : \(paths.root.path)
    spool    : \(paths.spool.path)
    sessions : \(paths.sessions.path)
    state    : \(paths.stateFile.path)
    config   : \(paths.configFile.path)
    log      : \(paths.logFile.path)
    """)
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    \(AgentAttentionVersion.displayName) \(AgentAttentionVersion.string) — menu-bar watcher for Claude Code sessions

      AgentAttention              run (menu bar only, no Dock icon)
      AgentAttention --selftest   run one refresh cycle and print the queue as text
      AgentAttention --uicheck    build the real panel and menu-bar item, verify layout, exit
      AgentAttention --uicheck --png <path>
                                  as above, and draw the rendered panel into a PNG. This renders
                                  this app's own view into a bitmap — it does not capture the
                                  screen and cannot see any other application.
      AgentAttention --uicheck --readability <dir>
                                  measure the panel and the bubble over white, dark and busy
                                  backdrops and write the composites there. Fixture evidence:
                                  these are this app's own views drawn over backdrops it made,
                                  not a picture of the panel over anybody's real window.
      AgentAttention --paths      print where data is stored
      AgentAttention --version

    Storage root is AGENT_ATTENTION_HOME, or ~/Library/Application Support/AgentAttention.
    """)
    exit(0)
}

if arguments.contains("--selftest") {
    // One pass of the refresh loop, printed as text. No window server involved.
    exit(HeadlessRunner.run(cycles: 1))
}

let application = NSApplication.shared

if arguments.contains("--uicheck") {
    application.setActivationPolicy(.accessory)
    func value(after flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { index -> String? in
            let next = arguments.index(after: index)
            return next < arguments.endIndex ? arguments[next] : nil
        }
    }
    exit(UICheck.run(pngPath: value(after: "--png"),
                     readabilityPath: value(after: "--readability")))
}

let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
