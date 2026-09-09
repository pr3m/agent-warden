import Foundation
import AgentAttentionCore

// aa-roam — Agent Warden's roam footer.
//
// `indicator` and `status` are read-only: they read `roam.json` off disk, exactly like `aa-status`
// reads its own state, and never touch the running app or any socket.
//
// There is no `on`/`off` here, and that is deliberate rather than an omission. Roam is controlled
// from Agent Warden's own menus — a short-lived CLI process cannot hold roam open itself, because
// the idle assertion and the daemon lease are held by whatever *live* process calls
// `RoamService.enter`, and that hold ends the instant the holder's process exits. Making `on`/`off`
// work from here would mean giving the always-running menu-bar app — the one thing on this machine
// watching every Claude Code session — a listening socket to receive that command on, purely to
// work around a CLI's own short-livedness. That is real, standing attack surface in exchange for a
// convenience, and it was judged not worth it: this app was already meant to drop its CLI in favour
// of its own UI, and reopening a socket to grow one back would undo that on the first task that
// touched it. If you want roam on or off, use the menu.

let arguments = Array(CommandLine.arguments.dropFirst())
let paths = AppPaths.resolved()

func loadState() -> RoamState? {
    guard let data = try? Data(contentsOf: paths.roamFile) else { return nil }
    return try? JSONCoding.decoder.decode(RoamState.self, from: data)
}

func liveness(_ pid: Int32) -> Double? { ProcessProbe.snapshot(pid: pid)?.startedAt }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

if arguments.contains("--version") {
    print("aa-roam \(AgentAttentionVersion.string)")
    exit(0)
}

switch arguments.first {
case "indicator":
    // Fast and silent by construction: one file read, one decode, no IPC. This runs on every
    // Claude Code status-line refresh, so it must never be the thing that makes a prompt feel slow.
    FileHandle.standardOutput.write(Data(
        RoamIndicator.text(state: loadState(), probe: liveness).utf8))

case "status":
    if let state = loadState() {
        if state.isLive(probe: liveness) {
            let minutes = Int(Date().timeIntervalSince(state.startedAt) / 60)
            print("roam on — \(minutes) min, owner pid \(state.ownerPID)")
        } else {
            // Not the same fact as "no roam.json at all", and worth saying so: this is exactly
            // the debugging distinction `RoamState.isLive` exists to make. `roam off` still
            // leads — this must never read as roam being on — but a file naming a dead owner, a
            // recycled pid, a stale lease, or a session already marked inactive is evidence of
            // *something*, and collapsing it into silence is the one thing "for debugging" (see
            // the usage text below) cannot afford to do.
            print("roam off (a roam.json exists but is not live — dead owner, recycled pid, "
                  + "stale lease, or the session was already marked inactive)")
        }
    } else {
        print("roam off")
    }

// No verb at all, or an explicit ask for help: print usage and exit 0, matching `aa-status
// --help` and `aa-bridge`'s own bare-command case — this is information, not a failure.
case nil, "--help", "-h":
    print("""
    aa-roam \(AgentAttentionVersion.string) — Agent Warden's roam footer

      aa-roam indicator   Print "🎒 roam on" when roam is active and validated, nothing otherwise.
                          For a Claude Code status line. Reads only; makes no IPC call.
      aa-roam status      Human-readable state, for debugging. Reads only.
      aa-roam --version

    Turning roam on or off is done from Agent Warden's own menus, not from here — see the note
    at the top of this file for why a CLI verb was judged not worth the socket it would need.

    Storage root: \(paths.root.path)   (override with AGENT_ATTENTION_HOME)
    """)
    exit(0)

// An actual typo or unsupported verb. Kept apart from the case above, matching `aa-bridge`'s
// own `default: fail("aa-bridge: unknown command …")` — a command nobody typed is help; a
// command somebody typed wrong is an error, and the two must not share an exit code.
default:
    fail("aa-roam: unknown command \(arguments[0])", code: 2)
}
