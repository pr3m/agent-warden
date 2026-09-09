import Foundation
import AgentAttentionCore

// aa-roam — Agent Warden's roam footer and control.
//
// `indicator` and `status` are read-only: they read `roam.json` off disk, exactly like `aa-status`
// reads its own state, and never touch the running app or any socket. `on` and `off` are not —
// a short-lived process cannot own roam itself. The idle assertion and the daemon lease are held
// by whatever process calls `RoamService.enter`, and that hold ends the instant the holder's
// process exits: a `aa-roam on` that entered roam itself would drop the block again before the
// command even returned. So `on`/`off` ask the *running app* to do it, over the same
// `BridgeSocketServer`/`BridgeRequest` machinery `aa-bridge` uses, at a socket Agent Warden opens
// for exactly this. If nothing is listening there, that is reported plainly — never silently
// treated as success.

let arguments = Array(CommandLine.arguments.dropFirst())
let paths = AppPaths.resolved()

func loadState() -> RoamState? {
    guard let data = try? Data(contentsOf: paths.roamFile) else { return nil }
    return try? JSONCoding.decoder.decode(RoamState.self, from: data)
}

func liveness(_ pid: Int32) -> Double? { ProcessProbe.snapshot(pid: pid)?.startedAt }

/// The socket Agent Warden itself listens on for roam control — started in
/// `AppDelegate.startRoamControlServer()`. Deliberately not `bridge.sock`: that path belongs to
/// the separate, opt-in `aa-bridge serve` process, which drives Claude Code sessions and has
/// nothing to do with roam.
let controlSocketPath = paths.root.appendingPathComponent("app.sock").path

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// How long to give the app to answer `roamOn`. Not `BridgeSocketClient.send`'s 30s default —
/// tracing why: its read loop (`BridgeSocket.swift`) treats *any* per-read timeout as final rather
/// than retrying up to its own overall deadline, so the wait it actually delivers is one slice
/// (`timeout / 3`), not `timeout`, whenever the server sends nothing until the whole answer is
/// ready — exactly what `handleRoam` does. `AppDelegate.performRoamOn` can legitimately take up to
/// ~20s (its own bound, with margin over `PowerLeaseClient.acquire`'s documented ~12s worst case),
/// so the slice here must clear 20s: 75 / 3 = 25s, giving 5s of headroom rather than an exact tie.
/// This is a real, pre-existing sharp edge in the shared client, not something introduced here —
/// see the task report for the trace and why it was mitigated at this call site instead of fixed
/// at the source.
private let roamOnTimeout: TimeInterval = 75

/// Send a roam verb to the running app and print its answer.
///
/// Every failure to reach the socket — no file, a stale one, a refused connection, no answer
/// inside the deadline — is reported the same honest way: Agent Warden is not running, or at
/// least not answering, so nothing was done. `on`/`off` must never claim success on a guess.
func sendRoamRequest(_ request: BridgeRequest, timeout: TimeInterval = 30) -> Never {
    let response: BridgeResponse
    do {
        response = try BridgeSocketClient.send(request, to: controlSocketPath, timeout: timeout)
    } catch {
        fail("Agent Warden is not running — start it, then try again.")
    }
    if response.ok {
        print(response.message ?? "done")
        exit(0)
    }
    fail(response.error?.message ?? "Agent Warden refused that request.")
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
    if let state = loadState(), state.isLive(probe: liveness) {
        let minutes = Int(Date().timeIntervalSince(state.startedAt) / 60)
        print("roam on — \(minutes) min, owner pid \(state.ownerPID)")
    } else {
        print("roam off")
    }

case "on":
    sendRoamRequest(.roamOn, timeout: roamOnTimeout)

case "off":
    sendRoamRequest(.roamOff)

// No verb at all, or an explicit ask for help: print usage and exit 0, matching `aa-status
// --help` and `aa-bridge`'s own bare-command case — this is information, not a failure.
case nil, "--help", "-h":
    print("""
    aa-roam \(AgentAttentionVersion.string) — Agent Warden's roam footer and control

      aa-roam indicator   Print "🎒 roam on" when roam is active and validated, nothing otherwise.
                          For a Claude Code status line. Reads only; makes no IPC call.
      aa-roam status      Human-readable state, for debugging. Reads only.
      aa-roam on          Ask the running app to enter roam. Fails if Agent Warden is not running —
                          a short-lived process cannot hold roam open itself.
      aa-roam off         Ask the running app to leave roam. Fails the same way if it is not running.
      aa-roam --version

    Storage root: \(paths.root.path)   (override with AGENT_ATTENTION_HOME)
    """)
    exit(0)

// An actual typo or unsupported verb. Kept apart from the case above, matching `aa-bridge`'s
// own `default: fail("aa-bridge: unknown command …")` — a command nobody typed is help; a
// command somebody typed wrong is an error, and the two must not share an exit code.
default:
    fail("aa-roam: unknown command \(arguments[0])", code: 2)
}
