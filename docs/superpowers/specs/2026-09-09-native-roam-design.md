# Native roam in Agent Warden

**Date:** 2026-09-09
**Status:** approved design, revised after independent review, not yet implemented

**Revision note.** The first draft of this spec was reviewed by GPT-5.6 Sol (via the
`codex` CLI, read-only). It found a privilege-escalation hole in the install design, four
places where the safety claims did not hold, and a correction I had introduced myself that
made the design worse. Sections 1, 2, 4, 6, the data model and the failure table were
rewritten. Findings I did **not** accept in full are recorded under *Known limits*.

## Goal

Agent Warden gains its own roam mode — keep the Mac awake and working with the lid
closed — controlled from Warden's own UI, with the bubble showing at a glance whether
roam is on.

Today roam lives in the `claude-code-roam` Claude Code plugin, and is turned on and off
with `/roam` and `/roam:off` from inside a session. That is the wrong place for it: the
decision to leave the desk is not a decision made inside one Claude session, and the
state it produces is machine-wide.

**Warden's roam must be standalone.** The plugin is expected to be uninstalled once
Warden reaches parity. Nothing in this design reads, writes, or requires any file the
plugin owns.

## Non-goals

- The plugin's `yolo` gate (PreToolUse Bash auto-approve). It is genuinely a Claude Code
  hook and belongs in `~/.claude/settings.json`, not in a macOS app. Out of scope here;
  it can stay installed independently or be reimplemented later.
- Remote control from a phone.
- Windows or Linux. Roam is macOS-only, as the plugin is.
- Developer ID signing and notarisation. Still out of scope (BACKLOG.md), and this design
  is built so it is not required.

## Decisions taken

| Question | Decision |
|---|---|
| Who owns roam? | Warden, natively. No dependency on `claude-code-roam`. |
| How does Warden get root? | A root LaunchDaemon installed by `install.sh`. Not SMAppService — that needs a Developer ID certificate, and this machine has no signing identities. |
| Scope | Core roam **plus hotspot awareness**. |
| The `/roam` skills | Retired. Warden UI, plus a thin CLI that talks to the running app. |
| Bubble indication | An outer halo ring, independent of the existing pending border. |
| Session footer | Warden ships its own indicator so `🎒 roam on` still appears. |

## What roam actually does

Three separate things, often conflated:

1. **Prevent idle sleep** — the machine does not sleep because nobody has touched it.
   Needs no privileges. A power assertion does it.
2. **Prevent lid-close (clamshell) sleep** — the machine does not sleep when the lid
   shuts. Apple classifies lid close as *forced* sleep, and ordinary power assertions
   explicitly cannot prevent it. The only lever is the global `SleepDisabled` setting,
   written by `pmset -a disablesleep 1`, and that needs root.
3. **Not lose your work when the battery runs out** — at a threshold, undo 1 and 2 and
   put the machine to sleep deliberately, while there is still charge.

## Architecture

```
   ┌────────────────────────────────────────────────┐
   │ AgentWarden.app (console user)                 │
   │                                                │
   │  RoamService ── IOKit assertion (idle only)    │
   │      │      ── battery guard (on the sweep)    │
   │      │      ── heartbeat + EOF watch           │
   │      │      ── IOPMSleepSystem (console user)  │
   │      │      ── RoamNetwork (hotspot, lid, HID) │
   │      │                                         │
   │      │  roam.json  (pid + start time stamped)  │
   │      │                                         │
   │  BubbleController ── inset disc + halo ring    │
   │  BubbleMenu / menu bar ── Roam on/off          │
   └──────┼─────────────────────────────────────────┘
          │  Unix socket, launchd-owned, 0600, peer-uid checked
          │  exclusive lease, renewed by heartbeat
   ┌──────▼─────────────────────────────────────────┐
   │ dev.agentwarden.powerd  (root LaunchDaemon)    │
   │   /Library/PrivilegedHelperTools/, root:wheel  │
   │   verbs: hello | acquire | renew | release |   │
   │          status                                │
   │   writes SleepDisabled via pmset, verified     │
   │   by read-back on every transition             │
   └────────────────────────────────────────────────┘

   aa-roam ──IPC──▶ running app          (on / off / status)
   aa-roam indicator ──reads──▶ roam.json ──▶ "🎒 roam on" in the footer
```

---

### Component 1 — `dev.agentwarden.powerd`, the privileged daemon

A new executable target. Runs as root under `launchd`.

#### Installation and ownership — the critical requirement

A root daemon that executes a **user-writable** binary is arbitrary root execution for
anyone who can write that file. Warden's whole existing pipeline revolves around
user-owned locations (`build/AgentWarden.app`, `~/Applications`, `~/.local/bin`), so this
trap is easy to fall into. The daemon must therefore be installed outside all of them:

| Item | Requirement |
|---|---|
| Binary | `/Library/PrivilegedHelperTools/dev.agentwarden.powerd`, `root:wheel`, mode `0755` |
| Plist | `/Library/LaunchDaemons/dev.agentwarden.powerd.plist`, `root:wheel`, mode `0644` |
| Every parent directory | root-owned, not group- or world-writable |
| `Program` in the plist | an absolute path; never a symlink into a user-owned tree |
| Linking | no `@rpath` or dylib that resolves inside the app bundle or the repo |
| Allowed-UID config | root-owned file written at install; **not** read from anywhere the user can write |
| Upgrade | atomic replace, then verify ownership and mode before the daemon is re-loaded |

The daemon must never load code, configuration or paths that the installing user can
modify. `install.sh` copies it there under `sudo`, and that copy is the only supported
location.

#### The socket — owned by launchd, not by the daemon

Declare the socket in the plist (`Sockets` → `SockPathName`, `SockPathOwner`,
`SockPathMode` `384` = `0600`) and obtain the descriptor with `launch_activate_socket`.

This removes the bind/unlink/stale-inode races entirely, has `launchd` create the endpoint
with the right owner and mode before any client can connect, and keeps the endpoint alive
across daemon restarts. It also avoids adapting `BridgeSocketServer.prepareSocketPath`,
whose `verifyPrivateParent` requires a `0700` directory owned by the current process — a
check a shared root directory can never satisfy.

`KeepAlive: true` stays. Socket activation fixes endpoint lifecycle; it does not by itself
get a crashed daemon back up to undo persistent `SleepDisabled` state.

#### Protocol

One line in, one line out. No arguments are parsed from the client into any command;
`acquire` and `release` map to two fixed `execve` argument vectors.

| Verb | Effect | Reply |
|---|---|---|
| `hello <version>` | Version handshake. Mismatch is refused with the daemon's version, so an upgraded app and a stale daemon fail loudly rather than subtly. | `ok <version>` / `error version <n>` |
| `acquire` | Take the exclusive lease and set `SleepDisabled` | `ok` / `error busy` / `error foreign` / `error <reason>` |
| `renew` | Refresh the lease deadline | `ok` / `error nolease` |
| `release` | Drop the lease and clear `SleepDisabled` | `ok` / `error nolease` |
| `status` | none | `held <seconds-remaining>` / `free`, plus the observed `SleepDisabled` |

**Exactly one lease exists.** A second `acquire` is answered `error busy`. Only the
connection holding the lease may `release` it, and only that connection's disconnect or
heartbeat timeout affects the setting. A short-lived `status` connection never owns
cleanup — that was an unstated hole in the first draft.

#### The lease is renewable, not merely connection-scoped

The first draft tied the lease purely to the socket connection. That covers Warden exiting
or crashing, but **not the failure that actually matters**: a Warden that is alive but
wedged — deadlocked, `SIGSTOP`ped, hung on the main run loop, or simply not running its
15-second sweep. In every one of those cases the socket stays open and the machine stays
awake indefinitely, with nobody guarding the battery.

So the lease has a deadline:

- The app sends `renew` every 10 seconds.
- The daemon clears `SleepDisabled` if no `renew` arrives within 45 seconds.
- The timeout runs on a **dedicated daemon timer**, independent of the connection-reading
  worker — a timer driven by the read loop would hang exactly when the read loop hangs.

Disconnect still releases immediately. The heartbeat is the backstop for the cases
disconnect cannot see.

#### `SleepDisabled` is global state, not a reference count

This is the correction with the sharpest teeth. `SleepDisabled` is a single machine-wide
boolean with no notion of ownership. Consequences the first draft got wrong:

- **"Whichever unblocks last wins" is backwards.** The *first* writer of `0` wins,
  regardless of who thinks they hold a lease.
- **Reverting to `0` on daemon start is destructive.** Verified live while writing this:
  `pmset -g` on this machine currently reports `SleepDisabled 1`, because the roam plugin
  is active right now. A daemon that "reverts to 0 on start when it holds no lease" would
  have silently turned off a roam session in progress.

Therefore:

- On `acquire`, read `SleepDisabled` first. **If it is already `1`, refuse with
  `error foreign`** and say that another tool or administrator owns the setting. Do not
  take it over.
- Every write is verified by read-back of `pmset -g`. `acquire` must observe `0 → 1`;
  `release` must observe `1 → 0`. Unverified means failed, and is reported as failed.
- On startup the daemon **reconciles rather than resets**: it holds no lease, so it clears
  `SleepDisabled` only if its own marker says it was the one that set it. No marker, no
  touching.

  The marker is a root-owned file at `/Library/Application Support/dev.agentwarden/held`
  (`root:wheel`, `0600`), written *after* `acquire` verifies `0 → 1` and removed *before*
  `release` writes `0`. It must be root-owned and outside every user-writable tree for the
  same reason the binary is: a user-writable marker would let anyone make the daemon clear
  a setting it does not own. It records nothing but the fact and the time.

Complete coexistence with unrelated writers is impossible — the setting has no ownership
identity. This is the honest limit, not a bug to engineer around.

#### Cleanup and recovery

`KeepAlive` is a likely recovery path, not a guarantee: `launchd` throttles restarts to
roughly one per ten seconds, will not restart a *hung* daemon at all, and stops restarting
entirely after `bootout`, uninstall, or a failed upgrade that leaves the binary missing.
So the daemon needs all of:

- Startup reconciliation, as above.
- `SIGTERM` handler that releases before exit.
- An explicit release step before any `bootout` in upgrade or uninstall.
- Verification that `SleepDisabled` is actually `0` before removal completes.
- A documented emergency repair, printed by the installer and in the README:
  `sudo pmset -a disablesleep 0`.

#### What the peer check does and does not buy

`LOCAL_PEERCRED` / `getpeereid` is sound authentication **of a UID**. It proves the peer
runs as the installed user. It does not prove the peer is Agent Warden — any process
running as that user can hold the machine awake. Without stable code signing, an
audit-token or code-requirement check would not meaningfully improve this. Stated as a
known limit rather than papered over.

#### `BridgeSocket` reuse — primitives only

The first draft said to reuse `BridgeSocket`'s server and client. That is wrong; four of
its assumptions are precisely inverted for a root daemon:

| `BridgeSocket` assumes | The daemon needs |
|---|---|
| `verifyPrivateParent`: parent dir `0700`, owned by this process | a shared root directory — the check cannot pass |
| stale socket must be owned by `getuid()` | socket is deliberately chowned to the installed user |
| server expects peer UID == its own UID | server (root) must expect the *installed user's* UID |
| client expects server UID == its own UID | client (user) must require peer UID `0` |

Additionally the existing server force-closes a connection after roughly three I/O
deadlines, and the client is explicitly one-shot and closes its descriptor before
returning — neither is compatible with a long-held lease.

**Reuse:** address construction, bounded framing, partial-write handling, and the
peer-credential plumbing. **Do not reuse:** `BridgeSocketServer` or `BridgeSocketClient`
whole.

#### Logging

Unified logging (`os_log`), not a file. A root daemon opening a user-writable log path is
a symlink and ownership hazard.

---

### Component 2 — `RoamService`

Lives in the app. Owns entering and leaving roam.

**Enter:**

1. Read battery and power source. Entering on battery is allowed — it is a legitimate
   thing to do — but the level is reported so the user knows what they are in for.
2. Take an IOKit power assertion: **`kIOPMAssertionTypePreventUserIdleSystemSleep` only**.
   The first draft also asserted display sleep; that is wrong here. With the lid shut the
   display is off anyway, and holding it awake would burn battery for nothing. Assertions
   are advisory and may be overridden under thermal or low-power emergencies — the design
   must not assume otherwise.
3. `hello`, then `acquire` on the daemon socket. Hold the connection; start the 10-second
   `renew` heartbeat and watch the socket for EOF.
4. Write `roam.json`.
5. Report the hotspot situation (see Component 3).

If step 3 fails for any reason — daemon absent, version mismatch, `error busy`,
`error foreign`, read-back unverified — **roam does not enter**, and the assertion from
step 2 is released. Idle sleep alone is not roam, and claiming roam is on when the lid
will still sleep the machine is the one lie this feature must not tell.

**Losing the daemon is an event, not a silent degradation.** EOF on the lease socket, or a
`renew` that fails, must immediately: mark roam off/failed in the UI, release the
assertion, and invalidate `roam.json`. The user finds out from the bubble, not from a flat
battery.

**Exit:** stop the heartbeat, `release`, confirm, close, drop the assertion, delete
`roam.json`. Idempotent — exiting when nothing is active succeeds silently.

**Battery guard.** Runs on Warden's existing 15-second sweep; no new timer.

At or below `roamBatteryThreshold` (default 10%) while on battery, in this order:

1. Post the notification, so a returning user sees why.
2. `release` on the daemon and **verify `SleepDisabled == 0`**. If this cannot be
   confirmed, the design cannot honestly promise deliberate sleep will work — say so in
   the notification rather than pretending.
3. Release the IOKit assertion.
4. Call **`IOPMSleepSystem` directly** and check its return code.

On `IOPMSleepSystem`: the previous revision of this spec claimed it requires root and
substituted `tell application "System Events" to sleep`. **That was wrong, and the
substitute was worse.** Verified against this machine's SDK header
(`IOKit.framework/Headers/pwr_mgt/IOPMLib.h`):

> `IOPMSleepSystem` — *"For security purposes, caller must be root or the console user."*

Warden runs as the console user, so it may call it directly. The AppleScript route is
unprivileged in the Unix sense but is gated by Automation/TCC, which can be denied,
revoked, or waiting on a prompt that nobody can answer with the lid closed — and Warden's
existing usage description covers controlling the terminal, not System Events. A direct
call with a checked return code replaces a permission dialog that may never be seen.

The guard does not fire on AC power, and cannot re-fire: roam has exited.

---

### Component 3 — `RoamNetwork`

Pure classification plus thin readers, so the policy is unit-testable.

**Hotspot kind, by default gateway:**

| Gateway range | Kind |
|---|---|
| `172.20.10.*` | iPhone Personal Hotspot |
| `192.168.43.*` | Android hotspot |
| `192.168.137.*` | Windows Mobile Hotspot |
| any other address | ordinary network |
| none | offline |

**The gateway is the primary signal and the SSID is best-effort.** The gateway needs no
permission; SSID reads are increasingly privacy-gated on modern macOS and Apple has been
closing command-line bypasses since macOS 14. Verified working on this machine today
(`ipconfig getsummary` returns an SSID, and the current gateway `192.168.2.1` correctly
classifies as an ordinary network) — but nothing may *depend* on the SSID being readable.
An unreadable SSID degrades the warning's wording, never the feature.

The Wi-Fi interface is **discovered** (`networksetup -listallhardwareports`), not assumed
to be `en0`. It happens to be `en0` here; that is not a design input.

**Uses:**

- Entering roam on an ordinary network while a hotspot is saved: warn *before* the lid
  closes. A warning, never a block — the user may know exactly what they are doing.
- The at-the-desk nudge: lid open **and** HID idle under a threshold **and** roam on for a
  while ⇒ show, once per snooze window, "You seem to be at the desk. Still need roam?"

Readers: gateway from `route -n get default`, lid from `AppleClamshellState`, HID idle from
`IOHIDSystem`. Each is bounded, and each failure reads as "unknown" — never as a false
positive that nags.

---

### Component 4 — the bubble halo

The bubble window is currently exactly the size of the disc, so anything painted outside
the disc is clipped — documented in `BubbleController.applyAppearance`, where the drop
shadow had to move to the window for the same reason.

**The root view currently *is* the disc.** `applyAppearance` sets the background colour,
corner radius and pending border on the root view itself. Simply growing the window would
therefore grow the disc, not create a margin around it. So:

- Introduce a **child disc view**, inset by `haloInset` (4pt), that takes over the
  background, corner radius and pending border.
- The window grows by 8pt permanently, whether roam is on or off. Always growing, rather
  than resizing on toggle, keeps geometry constant — no resize, no placement
  recomputation, no jump when roam flips.
- The halo is a separate layer in the margin, painted only when roam is on, so the orange
  "sessions are waiting" border is untouched and the two signals compose.

**Both geometry directions need the inset**, not just one:

- `BubbleGeometry.frame(for:size:in:)` — so the stored corner offset positions the *disc*.
- `BubbleGeometry.placement(for:in:)` — dragging persists through this; leaving it
  unchanged makes the bubble creep by 4pt on every drag.
- `panelFrame(...)` must anchor to the disc frame, not the halo window frame, or the panel
  gains a 4pt gap.

**Hit-testing:** `BubbleView.hitTest` currently returns the whole view for any hit, which
would make the transparent 4pt margin clickable and draggable. Decide explicitly — the
recommendation is that the margin is **not** part of the control: hit-test against the
inset disc bounds, so the halo is decoration and a click just outside the disc falls
through.

---

### Component 5 — menus

A `Roam` item in the bubble's secondary-click menu **and** the menu bar menu, built by a
single constructor in `BubbleMenu`, the way `quitItem` already is — so the two cannot
drift.

- Title reflects state: `Turn roam on` / `Turn roam off`.
- Disabled, with an explanatory title, when the daemon is absent, the version handshake
  fails, or the setting is held by something else (`error foreign`).
- Below it, when roam is on, a disabled status line: elapsed time, battery, lease health,
  and the hotspot warning if there is one.

---

### Component 6 — `aa-roam`

A new executable, symlinked into `~/.local/bin` alongside `aa-status`, `aa-emit`,
`aa-bridge` and `aa-session`.

**A short-lived CLI cannot own roam.** The first draft said these verbs sit "on top of
`RoamService`". That is wrong: the assertion and the lease are held by a live process, so a
CLI that entered roam would drop both the instant it exited. The CLI is a **client of the
running app**, over Warden's existing bridge socket — the same relationship `aa-status`
already has.

| Command | Behaviour |
|---|---|
| `aa-roam indicator` | Prints `🎒 roam on` when `roam.json` is active *and* validated (below). Reads one file, makes no IPC call — it runs on every status-line refresh and must be fast. |
| `aa-roam status` | Human-readable state, for debugging. |
| `aa-roam on` / `off` | IPC to the running app, which does the work. If Warden is not running, this **fails with that reason** rather than pretending. |

`on`/`off` still exceed the strict "UI only" decision and remain cuttable — nothing else
depends on them. They are kept because a machine-wide mode with exactly one front door is
awkward to script or recover from when the UI is the broken thing, and as IPC clients they
are now genuinely thin.

---

### Statusline installation and migration

`install.sh` offers to wire the indicator into `~/.claude/settings.json`, preserving what
is already there.

**This machine's current state must be handled specifically.** `statusLine.command` points
at `~/.claude/bin/roam-wrapped-statusline.sh`, a file the roam plugin generated and owns.
That file chains the user's own status-line script **and** carries a hand-added
third-party segment, with a comment warning that a plugin regeneration loses it.
Uninstalling the plugin deletes the wrapper and takes both with it.

So the installer must:

1. Detect a roam-plugin wrapper (`# roam-wrapped-statusline` marker).
2. Write Warden's own wrapper at `~/.claude/bin/agent-warden-statusline.sh`, carrying over
   **every** segment of the existing wrapper — the original command and any hand-added
   lines — with the roam indicator call swapped for `aa-roam indicator`.
3. Back up `settings.json` first and record the change in `install-manifest.json`, exactly
   as the hook wiring already does.
4. Show the resulting wrapper and ask before writing. This edits a file the user
   hand-tuned; it is not a silent migration.

Where there is no existing statusLine, write a minimal one. Where there is a non-roam one,
wrap it.

**`install-manifest.json` must never drive privileged removal.** It lives in the user's
data directory and is user-writable, so letting `uninstall.sh` delete arbitrary paths it
names would be a root-deletion primitive. Privileged paths (the helper binary, the plist,
the socket) are **fixed constants** in the uninstaller, ownership- and type-checked before
removal. The manifest governs only the unprivileged edits it already governs.

---

## Data

**`roam.json`**, in Warden's data directory
(`~/Library/Application Support/AgentAttention/`), written atomically at mode `0600` like
every other state file here.

```json
{
  "schema": 1,
  "active": true,
  "startedAt": "2026-09-09T12:00:00Z",
  "ownerPID": 4711,
  "ownerPIDStartedAt": 1757419749.0,
  "leaseRenewedAt": "2026-09-09T12:04:30Z",
  "enteredOnBattery": false,
  "hotspot": { "kind": "iphone", "ssid": "<name>" },
  "nudgeSnoozedUntil": null
}
```

**A static file cannot express "true only while a process lives".** A `SIGKILL` skips
`applicationWillTerminate`, leaving a file that says roam is on after both protections are
gone — and the footer would happily keep printing `🎒 roam on`. So the file is stamped with
the owning process fingerprint and validated on read, exactly as `app.json` already does
elsewhere in this codebase:

- `aa-roam indicator` treats the file as active only if `ownerPID` + `ownerPIDStartedAt`
  still name a live process **and** `leaseRenewedAt` is within the lease window. Otherwise
  it prints nothing.
- On app start, stale roam state is **deleted**, not adopted. Re-entering roam is
  deliberate.

**One state machine, resolving a contradiction in the first draft.** The draft said
`roam.json` is written only after a successful lease, *and* that it records
`sleepBlocked: false` when `pmset` fails. Both cannot be true. The rule is now:

> `roam.json` exists if and only if roam is fully established — assertion held **and**
> lease acquired **and** `SleepDisabled` verified. A failure at any step leaves no file.

The `sleepBlocked` field is gone; it existed only to describe a half-entered state that no
longer exists.

**Config** — new fields on `AttentionConfig`, all with safe defaults so an existing
`config.json` still loads:

| Field | Default | Meaning |
|---|---|---|
| `roamBatteryThreshold` | 10 | Percent at which roam exits and the machine sleeps. |
| `roamHotspotSSID` | `nil` | The network you expect to be on while roaming. |
| `roamNudgeEnabled` | `true` | The at-the-desk nudge. |
| `roamNudgeSnoozeMinutes` | 15 | How long a dismissed nudge stays quiet. |

## Failure modes

| What happens | What the user gets |
|---|---|
| Daemon not installed | Menu item disabled, saying so, pointing at `install.sh`. Roam does not enter. |
| Daemon version mismatch | Refused loudly at `hello`, naming both versions. Roam does not enter. |
| `SleepDisabled` already set by something else | `error foreign`. Roam does not enter; the menu says another tool owns it. |
| `pmset` write not confirmed by read-back | Treated as failure. Roam does not enter, assertion released, no `roam.json`. |
| Warden quits or crashes | Connection drops, daemon releases, assertion dies with the process. Machine sleeps normally. |
| **Warden alive but wedged** | No `renew` for 45s ⇒ daemon releases on its own timer. This is the case the connection-only lease missed. |
| Daemon crashes while roaming | App sees EOF ⇒ roam marked failed in the UI, assertion released, `roam.json` invalidated. `launchd` restarts the daemon; its marker lets it reconcile. |
| Daemon hung, or `bootout` during roam | `launchd` does not restart a hung daemon. Escape hatch, documented and printed by the installer: `sudo pmset -a disablesleep 0`. |
| Battery hits the threshold | Notify → release + verify → drop assertion → `IOPMSleepSystem`. If release cannot be verified, the notification says so. |
| The plugin is still installed and roaming | `acquire` refuses with `error foreign`. Correct behaviour, not a collision. |

## Testing

Pure and unit-testable in `AgentAttentionCore`, in the style of the existing suites:

- Roam state machine: enter, exit, idempotent exit, and refusal on each distinct daemon
  failure (absent, version, busy, foreign, unverified).
- Lease policy: heartbeat renewal, expiry on missed heartbeats, exclusivity (second
  `acquire` refused), and that a `status` connection's disconnect releases nothing.
- Transition verification: `acquire` refuses when read-back does not show `0 → 1`.
- Startup reconciliation: with a marker it clears; without one it does not touch.
- Battery guard: threshold, on-AC suppression, correct ordering, does not re-fire, and
  reports honestly when release cannot be verified.
- `roam.json` liveness: dead PID, recycled PID, stale heartbeat all read as inactive.
- `RoamNetwork` gateway classification, including ordinary-network and offline; SSID
  unavailable degrades wording only.
- Nudge policy: lid, idle and snooze windows.
- Halo geometry: the disc keeps its screen position across `frame(for:)` **and**
  `placement(for:)`; panel anchors to the disc; hit-test excludes the margin.
- Daemon protocol against a stub transport: verb parsing, unknown verbs, version
  handshake, lease ownership.
- Menu construction: one constructor, both menus, each disabled state.

Verified by hand, because they cannot be unit-tested: the real `pmset` write, the socket
under `launchd`, `IOPMSleepSystem`, and the halo's appearance.

Fault tests worth doing explicitly, by hand: `SIGKILL` the daemon, `SIGSTOP` the app,
`launchctl bootout` mid-roam, and a missing helper binary.

## Known limits

Recorded rather than engineered around. Each is a real constraint, not an oversight.

- **`pmset -a disablesleep` is an unsupported lever.** It is present in the current binary
  but absent from the `pmset(1)` man page, and Apple's supported closed-display workflow
  assumes external display, input and power — not battery operation. It may change or
  vanish without notice. Mitigation: verify by read-back after every write, and never
  claim success unless `SleepDisabled` matches. Acceptable for a personal utility;
  it would not be acceptable in shipped software without a fallback.
- **`SleepDisabled` has no ownership identity.** Perfect coexistence with other writers is
  impossible. Refusing when it is already set is the safest available policy.
- **The peer check authenticates a user, not an application.** Any process running as the
  installed user can hold the lease. Without stable code signing this cannot be tightened
  meaningfully.
- **SSID access is being progressively restricted.** Best-effort only; the gateway carries
  the feature.
- **Gateway ranges are heuristics.** Android vendors vary, USB tethering does not match,
  and IPv6-only routes exist. This drives a *warning*, never a block, so imprecision costs
  wording rather than correctness.
- **Fast user switching.** `IOPMSleepSystem` is permitted to root or the console user; a
  switched-away Warden may no longer be the console user. The return code is checked, and
  a refusal is reported rather than assumed to have worked.
- **Thermal.** Assertions are advisory and can be overridden under thermal emergency. The
  UI should carry the same warning the plugin does: a running Mac with the lid closed does
  not belong in a bag.

## Migration and coexistence

- Warden reads and writes nothing under `~/.claude/roam`. The plugin can be present or
  absent.
- Warden does not import the plugin's config. The hotspot SSID is one field, asked once.
- While both are installed, whichever acquires first holds `SleepDisabled`; the other gets
  `error foreign` and says so.
- Retiring the plugin is the user's step: `/roam:uninstall`, then remove it. The statusline
  migration above must happen **first**, because uninstalling deletes the wrapper file.
- `uninstall.sh` gains removal of the daemon, plist and socket — from fixed constants,
  ownership-checked — and restoration of the statusline, after verifying `SleepDisabled`
  is `0`.

## Build order

Four phases, each independently shippable and verifiable.

| Phase | Delivers | Verifiable by |
|---|---|---|
| 1. The daemon | Helper binary in `/Library/PrivilegedHelperTools`, plist with socket activation, exclusive heartbeat lease, verified transitions, reconciliation, `install.sh` / `uninstall.sh` wiring | `pmset -g \| grep SleepDisabled` across acquire/release; kill the client and watch it revert; `SIGSTOP` the client and watch the heartbeat expire; confirm `acquire` refuses when the setting is already `1` |
| 2. Roam itself | `RoamService`, idle-only assertion, heartbeat, EOF watch, `roam.json` with liveness, battery guard, `IOPMSleepSystem` | Enter roam, close the lid, confirm the machine stays up; force a low battery reading and confirm the ordered exit-and-sleep |
| 3. The UI | Inset disc view, halo, `haloInset` in both geometry directions, hit-test, menu item in both menus | Toggle from each menu; the disc does not move on upgrade or after a drag; halo and pending border compose |
| 4. The footer | `aa-roam` binary, statusline install and wrapper migration | `🎒 roam on` in a live session footer with the hand-added third-party segment intact; kill Warden and confirm the indicator stops printing |

Phase 1 is the only phase that touches the machine outside Warden's own data directory,
and the only one needing a password. Phases 2 and 3 are app work. Phase 4 edits
`~/.claude/settings.json` and a hand-tuned wrapper, so it is last and asks first.

## Open questions

None. Every decision needed to write the implementation plan is recorded above.
