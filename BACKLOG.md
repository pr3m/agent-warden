# Backlog

What this prototype deliberately does not do, and why.

## Done, and no longer a dependency

**Roam is native.** Keeping the Mac awake with the lid closed used to mean the external
`claude-code-roam` Claude Code plugin, and that dependency is gone: roam is built into Agent Warden
— a root `aa-powerd` helper owning `SleepDisabled` as an exclusive heartbeat-renewed lease, an
idle-only power assertion, a battery guard that sleeps the machine deliberately before the charge
runs out, and a `🎒 roam on` status-line segment served by `aa-roam`. `install.sh` migrates an
existing plugin status-line wrapper onto Warden's own, carrying every other segment through
verbatim, and asks first. The plugin can be uninstalled; nothing here needs it. See the
[Roam](README.md#roam) section of the README, including the
`sudo pmset -a disablesleep 0` repair.

Roam's own deliberate non-goals — a lease that authenticates a user rather than an application,
assertions macOS may override under thermal or low-power emergencies, and no attempt to keep the
*network* up — are recorded in the design's *Known limits*
(`docs/superpowers/specs/2026-09-09-native-roam-design.md`), not re-litigated here.

## Roadmap, in order

### Phase two — background shells, monitors and processes. Deferred, not started.

A coding agent leaves things running: dev servers, test watchers, Docker containers, background
shells, file watchers. They outlive the turn that started them, nobody tracks them, and they are a
common cause of a machine slowing to a crawl or a port being mysteriously occupied. The intended
shape is a second view — same bubble, same panel — listing what each session has left running, how
long it has been alive, and a way to end it.

**Explicitly out of scope now.** No process-tree walking beyond identifying the Claude Code process
for liveness, no container inspection, no port scanning, no process control. The groundwork exists
(`ProcessProbe` reads the tree read-only, each session record carries its pid, `aa-status` has a
place to put a second list), but nothing of phase two is implemented.

0.5 takes the first honest step towards it: the `Stop` hook's `background_tasks` array is read, so
the app knows *how many* background tasks a session left running and of what type. That is a count,
not an inventory — no pid, no port, no command, no way to end anything. The phase-two overview is
still unbuilt.

### Also on the roadmap, and deliberately not built

| Idea | Where it stands |
|---|---|
| **Sounds** | A short distinct tone per attention class, as an alternative to speech for people who want a signal without a sentence. Not built: speech already exists and is off by default, and adding a second audible channel before anyone has asked for one is noise. Would reuse the same rate limit. |
| **Work-arc phases** | Showing where a session is in its arc — planning, implementing, verifying — rather than only whether it is waiting. Attractive, and the reason it is deferred is that no hook reports it. Deriving it would mean reading transcript content, which is a standing non-goal. Revisit if Claude Code emits a phase or mode signal. |
| **Event subscription instead of polling** | Something that wants to *react* to the queue rather than ask it. Today the interface is `aa-status --json`, polled. A subscription would need a socket or an MCP server with a lifecycle to manage; the poll costs one process spawn and has no lifecycle at all. Revisit when there is a consumer that genuinely cannot poll. |

### Assistant-operable session creation, prompts/replies and progress — deferred, not started

Provide a supported assistant-facing interface through Agent Warden to create a new official
Claude Code session, submit a prompt or authorised reply, and observe acknowledged activity,
progress and the resulting output/completion. This extends the existing two-way voice-assisted
project-management idea; it is one backlog item, not a second competing integration.

**Current gap:** installed 0.10.1 exposes read-only status and recent context. It cannot create
sessions or send prompts/replies. Launching Claude separately from a shell does not demonstrate
that these operations work through Warden. Recording this item is not implementation approval.

Acceptance example:

1. Through Warden's assistant-operable interface, create a new disposable Claude Code session in
   a scratch location and return its verified full identity.
2. Through that same interface, send a harmless hello-world request and verify acknowledgement
   by the intended session. Prevent duplicate sends and route by verified identity.
3. Observe genuine activity, then confirmed completion and the actual result/output end to end.
   Distinguish waiting for a user, failure and uncertainty; do not infer completion from silence.
4. Leave all existing sessions unchanged: no prompts, restarts, input injection, commits or pushes
   against them. Use official subscription authentication without assuming an API key.

**Separate access requirement:** expose reliable assistant access to individual session controls,
through accessible UI semantics or another supported interface. The current computer-use
connection exposes the live bubble/menu but not individual rows/context controls. Address and
verify that reachability separately: accessible controls alone do not create a missing launch/send
API, and a working API does not prove the desktop controls can be operated.

Prerequisites remain a supported, permitted session-control integration; explicit authorisation
for replies/continuations; reliable routing and acknowledgement; observable results; and truthful
failure reporting. Do not use synthetic keystrokes or terminal scripting to inject input. Live
voice delivery/wakeups require their own supported connection and must be verified separately.

**Delivered:** the bridge starts, sends to, stops and adopts sessions with acknowledgement,
authorization and an audit log, and `aa-mcp` exposes it to a local MCP client (README § The session
bridge). Still open: live voice delivery and wakeups, and the accessible per-row controls above.

## Session discovery — what it does not do

Discovery lists sessions that were already running. It stops there, on purpose:

- it never infers attention or activity from the registry, and `status: busy` is shown verbatim
  rather than read as a state;
- it never counts a discovered session as working;
- it never opens `*.key` peer tokens, and never connects to `messagingSocketPath`;
- it never reads a transcript beyond a bounded tail, and takes only `cwd`, `gitBranch` and
  `sessionId` from it;
- it writes nothing, anywhere.

Deliberately not built on top of it: reading a session's *state* from the registry (the field is
stale by design), naming sessions from transcript content, or watching the registry directory with a
file-system event source rather than a 20-second poll — the poll is cheap and one fewer moving part.

The registry is Claude Code's internal bookkeeping, not a published API. If its shape changes,
discovery degrades to nothing and hook-driven monitoring is unaffected.

## Considered and deferred

| Item | Why not now |
|---|---|
| **Automatic session→tab mapping in Ghostty** — **DONE (0.14)** | Delivered, and not by the route this entry expected. The premise here was that Ghostty exposes a terminal's id, name and working directory but not its pid or tty, so a session cannot learn which surface it occupies — true, and it makes *matching* on a name or a directory a guess that picks the wrong tab whenever two sessions share a project. It does not make the question unanswerable. Warden writes a one-time token as the title of the tty the session is actually running on, then asks Ghostty which terminal is now called that. Only one can answer, and the title is put straight back. That is a challenge-response, not a derivation, so it tells four tabs in one repository apart. Recorded with `provenance: derivedHandshake`, distinct from `userConfirmed`. Ghostty is not upgraded, restarted or controlled, nothing is typed into a session, and a session that does not answer — tmux, another terminal, none at all — stays unlinked rather than being matched to the closest-looking tab. Upstream PR 11922 is no longer a blocker for this. |
| **Automatic avoidance of other apps' floating controls** | Would need window-list geometry this app does not ask for, and could not be promised across every app and space. Instead: a default that clears the corner, drag, and a corner/nudge menu. |
| **MCP server** — **DONE** | `aa-mcp` serves the bridge's operations over stdio, stateless, one host request per tool. Not built: event *subscriptions* — a client polls `warden_session_events` with a cursor. `aa-status --json` remains the cheapest read for status alone. |
| **Multi-client event collection** (Codex, Cursor, other agents) | The event schema is client-neutral and versioned, and the emitter takes its classification as an argument, so a second client needs an emitter invocation and nothing else. Not built: only Claude Code hooks are wired. |
| **Transcript *ingestion*** | Reading a conversation on request is built (`--session … --context`). *Ingesting* one is not, and will not be: nothing reads content on a timer, into the queue, into `state.json` or into a log. Content is produced for one explicit query and returned to that caller. Would mean storing session content. A deliberate non-goal — see the tests that fail if prompt or assistant text reaches disk. The most a card carries is the hook's own one-line message, and only if `includeHookMessages` is on. |
| **Code signing, notarisation, distribution** | Ad-hoc signed so macOS keeps a stable identity for Automation grants. Developer ID, notarisation and a release channel are out of scope. |
| **Keyboard focus on the bubble** | The bubble and panel are non-activating on purpose — that is what stops them interrupting typing. Making them focusable would undo it. The menu bar item carries the same actions for keyboard-only use. |
| **A settings window** | Everything is in the menu or `config.json`. |
| **Per-project rules** ("never alert me about work completing in `scratch`") | Config is global. Straightforward to add; no demand demonstrated yet. |
| **Async hooks** (`"async": true`) | Would shave the few milliseconds a hook adds. Not used because stdin delivery for async hooks is unverified here, and a silently dropped hook is a wait the app never learns about. |
| **Inferring anything from elapsed silence** | Removed outright in 0.5, not lengthened. A legitimate task runs for hours and is indistinguishable from a stuck one from the outside. Any future revival would need a signal that actually says *stuck* — not a timer. |
| **Windows / Linux** | The emitter is portable in principle; the app is AppKit. |

## The communication bridge — active priority

**Delivered (0.11.0):** a local, owner-only interface for sessions Agent Warden starts itself —
create in an approved directory, send a turn, follow up in the same session, and distinguish
accepted, client-acknowledged, active, result, completed, failed and uncertain. Proven once against
a real disposable session.

**Not delivered, and each its own piece of work:**

| Piece | Why it is not done |
|---|---|
| A channel into a session already open in a terminal | Claude Code channels are opted into when that session *starts*; a custom channel additionally needs a preview flag and local consent. Nothing may enable or restart someone's running session |
| Voice wakeup — an event reaching a live ChatGPT voice conversation | No supported third-party injection endpoint has been established. Local bridge events do not prove a voice wakeup |
| Orchestrating the four open worktree sessions | Follows from the first row. Until a channel exists, those sessions are observed and not driven |
| Retrospective recovery of a request missed before the handoff rule existed | Proposed as an app-owned startup reconciliation; deliberately not built |

## Known rough edges

- **`AttentionEngine` is main-thread only** by convention, not enforcement.
- **The MCP read path is deliberately unscoped.** `approvedRoots` governs what the bridge may
  *touch*, not what it may *see*: `context` and `summary` return any live session's recent prose,
  including projects never listed in `bridge.json`. Chosen knowingly — any process running as this
  user can already read `~/.claude/projects` directly, so the exposure is to a narrow-tool-list MCP
  client rather than to a local attacker. Both calls are now recorded in the audit log (operation
  and session only, never the content), so an enumeration no longer looks identical to doing
  nothing. Revisit by adding `isApproved(cwd)` to both, or a separate `readableRoots`.
- **`authorization` is the caller's word, and the voice agent auto-approves.** The two combine into
  a confused-deputy path with no technical barrier: session A summarises attacker-influenced text,
  the agent reads it through `warden_session_context`, then calls `warden_send_prompt` on session B
  asserting its own approval. Narrowed by `SessionContext` dropping `tool_result` payloads, so raw
  fetched content never comes back — only the assistant's own words about it. The only control that
  would bind is out-of-band confirmation — a destructive `via == mcp` request requiring a click in
  the menu-bar app. **Deliberately not built, and this is settled rather than pending.** Handing an
  agent the ability to drive Claude Code sessions at all is granting it the machine; a click in
  front of one tool it holds, while it holds others, buys nothing but friction. The perimeter is
  wherever that agent gets its authority, which is not this repository. The residual this does not
  cover is a trusted agent being *misled* by content it read, and that only lands here if warden
  ever becomes its only powerful tool — if that day comes, `BridgeService` already holds the
  control socket and `focusForBridge` shows the pattern. The audit log earns its keep either way:
  not as a barrier, but as the way to reconstruct what happened.
- **`warden_start_session` is annotated destructive but takes no `authorization`.** Nothing about
  spawning a client in an approved root is the user's word to give, so there is no statement to
  record — but it means the audit log has no vouching line for starts, unlike send/adopt/stop.
- **The supervisor's launch-window fix has no unit test.** `stop()` now waits on a `launching` flag
  so it cannot report a clean shutdown while a child is mid-spawn. A deterministic test needs a
  barrier injected into the launcher; a timing-based one would add flake to the suites immediately
  below, which are already unreliable. Covered indirectly by `Scripts/smoke-test.sh` asserting that
  no client the host started outlives it.
- **A duplicate concurrent adopt/terminate can answer with a stale phase.** The loser of the
  `claimExit` race reports `awaitingDetach` though a signal was just sent. The signal is still sent
  exactly once and the persisted ticket self-corrects; only that one response is briefly wrong.
- **The bridge lifecycle suites are not reliably green.** `Bridge third-round corrections` and its
  neighbours failed twice in seven consecutive runs of `Scripts/test.sh`, with a different issue
  count each time (14, then 13), then passed five times in a row with no change in between. They
  turn on pipe teardown, descriptor lifetime and bounded waits, so a slow or loaded machine changes
  the answer. Treat a single green run of those suites as weak evidence, and do not read a failure
  there as a regression until it repeats.
- **One `--uicheck --png` assertion has been red since before the zone work.** The screenshot
  fixture links its first session to a tab whose name differs from the worktree, so the row
  correctly shows the tab name — while the check still asserts the worktree name is on screen.
  The panel is right and the assertion is stale; plain `--uicheck` is unaffected.
- **Speech rate-limits to one utterance every four seconds.** A burst announces once; the panel
  still shows all of them.
- **The heartbeat file is overwritten, not appended.** If two hooks fire between two reads, only
  the later one is seen — intentional, and harmless, because the later signal is the more accurate
  description of the session state.
- **Two hooks landing in the same millisecond** are ordered arbitrarily.
- **The bubble is placed by configuration, not by looking at the screen.** If another app's control
  moves onto it, you move ours.
- **The session list has no scrolling.** It shows at least eight rows, says "+N more tracked" for
  the rest, and **Show all N sessions** expands it in place. With very many sessions the expanded
  panel is tall; the full list is also in `aa-status`.
- **The `⋯` menu is the only secondary surface.** There are no per-row buttons, so every secondary
  action costs one extra click. That is the trade for a row whose name is readable.
- **An Apple event already delivered cannot be recalled.** If a `focus` reaches Ghostty and the
  reply is late, the tab may still change after Warden has given up waiting and reported a timeout.
  Nothing *unsent* is ever sent late, and nothing queues behind a blocked script — but the last inch
  belongs to the operating system.
- **A click during a slow Automation call does nothing but say so.** Requests are refused rather
  than queued, which is the right trade for navigation and a small annoyance the first time it
  happens.
- **Sound is one switch, not per-session.** Muting is global. There is no "mute this session", and
  no notification history — nothing that happened while muted is announced afterwards, by design.
- **Background-task evidence is only as fresh as the last `Stop`.** Nothing tells us when a task
  *finishes*, so the reading expires after 30 minutes rather than being updated, and the session
  then reads *uncertain* rather than paused. A session may show as paused for a few minutes after
  its work actually completed.
- **"Uncertain" will be common in practice.** Any turn whose `Stop` payload is incomplete lands
  there, and it makes `aa-status --waiting` answer 2 rather than 1. That is the intended trade:
  a script that wants a definite "all quiet" should get one only when the evidence supports it.
- **The bubble's Quit is not exercised end to end here.** The menu is built, wired and its action
  fires in `--uicheck` against a stub; terminating the real app inside a check would end the check.
  Actual quit-and-relaunch behaviour is verified on the installed build.
- **A branch reading is up to a minute old.** It is re-read on the sweep, not watched. A branch you
  switch is reflected within the minute, and the reading carries its own timestamp.
- **The conversation window reads a 1 MiB tail.** A session whose recent exchange is longer than
  that shows only the end of it, and says so. On a very long turn the tail can be all assistant
  messages, with the request that started it further back.
- **A session name comes from the folder** unless Claude Code has given it a title. Two worktrees
  with the same leaf name look alike in the list; **Details** distinguishes them by full session id.
- **The display name is provisional.** Repository, modules, bundle-id prefix and data directory
  keep the `AgentAttention` spelling; only user-facing strings say "Agent Warden".
- **A bridge client's stated timeout is a third of what it waits.** `BridgeSocket.swift` sets
  `SO_RCVTIMEO` to `timeout / 3` so a stalled trickle cannot hang forever, but the read loop treats
  every `recv` error except `EINTR` as fatal — and a socket read timeout reports `EAGAIN`. The first
  quiet third therefore ends the call. A caller asking for 30 seconds gets 10. The fix is to treat
  `EAGAIN`/`EWOULDBLOCK` as "keep waiting until `hardStop`", which is what the surrounding
  `while Date() < hardStop` already assumes.
- **The at-the-desk roam nudge is configured but not implemented.** `roamNudgeEnabled` defaults to
  `true` and `roamNudgeSnoozeMinutes` to 15, and `RoamState` carries `nudgeSnoozedUntil`, but
  nothing reads any of it: no code path ever offers to turn roam off when the lid is open and you
  are back at the machine. The settings are therefore inert, and read as a feature that exists.
  Either build the nudge or drop the two keys — a default of `true` for something that never
  happens is the worse of the two states.
- **Adoption ends the terminal's client; it cannot detach it.** Claude Code has no supported way to
  hand an interactive client's conversation to another process while it runs, so the handoff is
  "exit, then resume": by you, or by one SIGTERM while idle. The original tab is not reused.
- **Authorization is the caller's word.** The host cannot see a person; it refuses a change without
  a confirmed statement and records the statement. An MCP client that fabricates one is caught only
  by its own approval prompt (the tools are marked destructive) and by the audit log afterwards.
- **The writer check is only as good as Claude Code's registry.** It runs before every send to an
  adopted session, so a second client that starts in the milliseconds between check and write is
  missed for that one write, and a client that never registers is never seen.
- **A crashed host takes its sessions' clients with it.** The app restarts the host, which starts
  empty; the conversations are on disk and can be adopted again once Warden observes them.
- **A host orphaned by an app crash keeps the socket.** The relaunched app treats it as another
  host and waits for it to go rather than replacing it.
- **Exact-tab focus of an observed session needs the app.** The host asks the app, which owns the
  links; with the app not running the answer is "unavailable", never a guessed tab.
- **`aa-mcp` is bundled but not linked or version-checked by the installer.** Point an MCP client
  at the bundle path. Adding it to `install-app.py` touches a file on the heavy list.
