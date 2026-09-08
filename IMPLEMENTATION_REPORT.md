# Implementation report — Agent Warden 0.13.0

Built on macOS 26.6.2 (arm64), Swift 6.3.3, **Command Line Tools only — no Xcode**. Display name is
"Agent Warden"; the repository, Swift modules, bundle-id prefix and data directory keep the original
`AgentAttention` spelling.

This report describes the current state of the app and what was verified. Earlier passes are not
reproduced here; `README.md` is the behavioural reference and `BACKLOG.md` is the list of things
deliberately not built.

---

## 1. The rule the app is organised around

**Only say what the evidence supports.** Three claims are always kept apart:

| Claim | What backs it |
|---|---|
| *This session needs you* | An official Claude Code hook that is a genuine request — a question, an approval, a stage decision, an error |
| *This session is busy with its own work* | A `Stop` payload whose task and cron lists both read cleanly and show something pending |
| *We could not tell* | Everything else — and it is **silent** |

Nothing is derived from elapsed time. Nothing is derived from a payload we could not fully read.
A card, a badge count and a spoken alert are all the same commitment, and none of them is made on
anything weaker than the first row.

---

## 2. What changed in 0.6

### 2.1 Uncertainty is passive

Previously a `Stop` that carried no readable task data still produced a card, worded "completion not
confirmed". That is still an alert about something nobody asked for. Now:

| Signal | Before | Now |
|---|---|---|
| `Stop`, no task arrays | `workComplete` card | no card; session state `unknown` |
| `Stop`, `tasks: []`, no cron list | `workComplete` card | no card; the missing list is a hole in the evidence |
| `Stop`, `tasks: []`, `crons: [wakeup]` | `workComplete` card | no card; a scheduled wakeup is pending work |
| `Notification/agent_completed` alone | `workComplete` card | no card — it carries no evidence |
| `Notification/idle_prompt` alone | `idle` card | no card — a state, not a request |
| `Stop`, both lists present and empty | `workComplete` card | unchanged: this is the only confirmed completion |
| `Stop` with a failed task | `workComplete` card, "…failed" | raised as **`error`**, even while other tasks run |

Generic signals still fold into an ask that is already open — the occurrence count goes up, the
ask's own description is kept. Counting a repeat is not manufacturing urgency.

### 2.2 Claims are withdrawn when the evidence turns

A "turn complete" card followed by a `Stop` reporting work still running is a contradiction. The
card is now removed (`.resolved(reason: .evidenceWithdrawn)`) and the session becomes
`backgroundWaiting`. Only *generic* items are ever withdrawn this way; a question, approval, stage
decision or error is never withdrawn on the app's own initiative, and keeps its snooze.

### 2.3 A request outranks a pause

A session with an open ask stays `awaitingUser` when a background `Stop` arrives. The ask is what
the user is being asked for; the background work is secondary and is not counted as a quiet pause.

### 2.4 The pause is about now, not about a snapshot

`isWaitingOnBackgroundWork` now requires the session to actually be in `backgroundWaiting`, not just
to carry an old reading. A session that does real work again is *working*, and the reading is kept
as-is rather than rewritten into a completion to tidy a count. When a reading ages past its TTL the
sweep moves the session to `unknown`, so a later idle prompt still cannot turn it into an alert.

### 2.5 The parser requires a complete shape

`session_crons` is now read. Both arrays must be present and well-formed; a cron entry is pending
work. A missing, wrong-typed or malformed cron list makes the whole reading `unknown`. Failure
detection outranks everything else in the reading.

### 2.6 Migration repairs state, not just links

Restoring an old queue drops two kinds of record and repairs what pointed at them:

- a `suspectedStall` from a build that still inferred them;
- a generic completion or idle card the session's own evidence no longer confirms.

In both cases the session's activity is moved from `awaitingUser` to `unknown` — clearing the link
while the row still read "waiting at the prompt" would have kept the same false claim without the
card. Real asks, their snoozes and their dismissals are untouched.

### 2.7 The bubble has a context menu

Right-click, or control-left-click, opens the bubble's own menu: the badge count, show/hide
sessions, bubble position, reveal the data folder, and **Quit Agent Warden**.

- Routing is explicit (`BubbleView.route(button:modifiers:)`). Opening the menu cancels the pending
  press, so it never also toggles the panel and never begins a drag. Plain click, drag and the
  three-point drag slop are unchanged.
- **One Quit constructor.** `BubbleMenu.quitItem(target:action:)` builds the item for both the
  bubble menu and the menu bar item, so there is a single termination path rather than two that
  could drift. It calls `NSApp.terminate`, which runs `applicationWillTerminate`: save the queue,
  clear the presence file, stop the watchers. It touches nothing else — not the hooks, not
  `settings.json`, not the login item. The login item is `RunAtLoad` with `KeepAlive` off, so
  quitting does not respawn the app.

### 2.8 Cursor scoping

- `hitTest` no longer waves through anything that is an `NSControl`. `NSTextField` is one, so a
  plain label was keeping its own I-beam and swallowing the card's click. The test is now whether
  the view is genuinely interactive: an *enabled* control, or a field that is editable or
  selectable. Real text fields keep their I-beam and their clicks.
- Entry and movement events set the cursor; state changes under a stationary pointer need explicit cleanup.
  Disabling a control, a row ceasing to be clickable, and a view being hidden or removed now hand
  the cursor back explicitly — and only when that particular view is the one under the pointer, so
  nothing reaches out and resets an unrelated control's cursor.

### 2.9 Honest counts, honest copy

- `aa-status`: `sessions[].attention` is now `waiting` / `none` / `uncertain` / `awaitingFirstHook`,
  reported apart from `hookCoverage`. Having heard from a session once does not make its current
  state known. An uncertain session raises a warning, so `answerIsTrustworthy` is false and
  `--waiting` answers 2 rather than 1. New count: `counts.sessionsUncertain`.
- Panel and bubble: "No attention needed" and "No sessions need you" became **"No confirmed
  requests"**, with coverage, background work and uncertainty listed separately.
- Session names are no longer clipped at 80 characters by the registry parser (240 now), so a real
  worktree-plus-task name survives to the row that wraps it and to Details.

### 2.10 Readability, from the render

The subtitle has its own full-width wrapping line; the card's age and source line has its own row
instead of being squeezed beside four buttons; supporting text uses fixed light values with real
contrast against the HUD blur rather than `tertiaryLabelColor`, which is grey-on-grey there; the
session row's state wraps in a measured column instead of truncating.

### 2.11 The notification toggles suppress an alert, and nothing else

`applyAttention` used to early-return into a `park()` helper for three cases: a replayed
`suspectedStall`, `notifyOnWorkComplete = false`, and `notifyOnIdle = false`. `park` ran before any
evidence handling and unconditionally set the session to `awaitingUser`. Three consequences, all
wrong:

| With completion alerts off | Was | Now |
|---|---|---|
| `Stop`, no readable evidence | `awaitingUser` | `unknown`, and the reading is recorded |
| `Stop`, a task still running | `awaitingUser` | `backgroundWaiting`, counted as a pause |
| `Stop`, a task **failed** | nothing at all | raised as an **error** |

And a replayed `suspectedStall` could turn a working session — or one with an open question — into
"waiting for you", on the strength of a record the app no longer believes in.

`park` is replaced by `noteHeardFrom`, which records identity and the last-seen clock and changes
nothing else. The toggles are now read inside the generic branch as `alertAllowed`, so they suppress
the card while state, evidence reconciliation, withdrawal and failure detection all still run. A
suppressed *confirmed* completion still reads `awaitingUser`, because the turn did finish.

### 2.12 Confirmed evidence is spent once work resumes

A confirmed `Stop` describes the turn it ended. Previously it stayed on the session indefinitely, so
a later `Notification/agent_completed` carrying no evidence of its own would reuse it and manufacture
a completion for a turn that had not ended. `SessionState.backgroundSupersededAt` is set when
activity or a session start follows a reading; `completionCertainty` then returns `.uncertain` for
that reading. The reading itself is kept — it is still the best description of what the session left
running — and a new `Stop` confirms again on its own evidence.

### 2.13 A disabled control is not a pass-through

`hitTest` deferred anything `isInteractive` rejected to the clickable parent, which included
*disabled* buttons — so pressing a greyed-out control could activate the card behind it and open a
terminal. Hit-testing now asks a different question (`isDecoration`): only a non-selectable label, an
image or a bare container defers. A disabled control keeps its own hit, does nothing with it, and
shows an arrow. `mouseUp` also re-reads `isClickable`, so a row that stops being clickable between
press and release does not still act.

### 2.14 Clicking away closes the panel

The one feature added before installation. Click anywhere that is not Agent Warden and the expanded
panel folds back to the bubble.

**It is presentation, and only presentation.** Nothing is dismissed, snoozed or resolved; the badge
count is unchanged; snoozes still stand; one click on the bubble brings the same cards straight back.
The handler is `collapseForPresentation()`, which sets two view flags and re-renders — it does not
call the engine at all.

`OutsideClickWatcher` uses a **global mouse monitor**:

- a global monitor sees only events delivered to *another* application and **cannot consume them**,
  so whatever the user actually clicked receives its click in full;
- it needs **no Accessibility grant** — that requirement is for keyboard monitoring. The app asks for
  no new permission;
- clicks inside our own windows never reach a global monitor at all; they are local events. The
  panel, the bubble, their buttons and the drag handling therefore need no special case;
- `NSMenu` is the one exception, because it runs its own modal tracking loop. While one of our menus
  is tracking, and for 0.3 s afterwards, outside clicks are ignored — otherwise opening **Details**
  on a card would collapse the panel out from under the menu just asked for. That settling window is
  for a single event-ordering ambiguity and nothing else depends on elapsed time.

The rule is a pure function (`shouldCollapse(panelIsExpanded:at:)`) with an injectable clock, so all
five cases — closed, open, menu-open, just-after-menu, later — are exercised directly.

### 2.15 The discovery fixture compiles its helper

`Scripts/smoke-test.sh` used `cp /bin/sleep` to stand in for a running Claude process. Copying a
system binary strips its code signature and macOS then kills the copy on launch — reproduced here as
exit 137 (SIGKILL), entirely independent of this app. The fixture now compiles a four-line C sleeper
with `cc`. No assertion changed; the section simply stops failing for a reason that was never about
the product. If `cc` is unavailable the fixture reports a failure rather than skipping quietly.

### 2.16 The worktree is the name; the identifier goes to Details

Claude Code's registry supplies `name` and `nameSource`. Only a name whose source says a person chose
it (`user`, `custom`, `explicit`, `manual`, `set`, `named`) is used as the label. Observed values here
are `derived` and `auto`, producing `redmy-36`, `redmy-0c`, `redmy-6e`, `redmy-e9` — four sessions in
one repository, two characters apart. Those are identifiers. The row shows the **worktree**; the
generated label is preserved verbatim in Details with its source. No name is derived from transcript
content or from a model.

### 2.17 The branch is read from the directory

The transcript stamps `gitBranch` at session start and never revisits it. Verified here: all five
live worktree sessions reported `main` while actually on `cs/client-info-t1`,
`cs/red658-plan-vs-ledger`, `cs/sensitivity-train`, `cs/red645-own-capital` and
`cs/exec-cashflow-truth`.

`GitBranchProbe` runs `git -C <cwd> --no-optional-locks branch --show-current`, off the main thread,
with `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, no stdin, a 2-second timeout and a kill after
it. Arguments go as an argument vector — there is no shell, so an awkward path is just a path. Five
outcomes are kept apart and none is ever rounded up to a name: `branch`, `detached`,
`notARepository`, `denied`, `timedOut`.

`AttentionEngine.apply(branch:sessionID:)` writes one field. It refuses a reading taken at a
directory the session has since left, refuses one older than what it already has, and touches
neither `cwd` nor any attention state. It applies to hook-covered sessions too: hook coverage does
not make a value that was never read from a directory correct.

### 2.18 Asking what a session is working on

`aa-status --session <full-session-id> --context [--json]`, and **Details → Recent conversation…**
in the app. The only part of the app that reads message content, and it reads it only when asked.

- Located by **full** session id; every record checked to carry that same id, so another session's
  conversation cannot be shown. Symlinks resolved and required to stay under `~/.claude/projects`;
  regular files only.
- Excluded: thinking, tool inputs, tool result payloads, attachments, subagent sidechains.
- Bounded: 1 MiB tail, 20 messages, 600 characters each, 12 000 total; partial first line dropped;
  `read(upToCount:)` because the file is growing while we read.
- Never cached, never persisted, never logged, never folded into the queue. It cannot raise an item
  or clear one.
- Attention state is reported **beside** it, from hooks, labelled authoritative, and stays visible
  when the transcript cannot be read at all.
- `AskUserQuestion` is quoted as written and correlated to its `tool_result` by `tool_use_id`. With
  the correlating record outside the window read, the answer is **unknown**, never "unanswered".

Exit codes: `0` read · `2` usage · `3` no transcript · `4` unreadable. stdout for the report, stderr
for problems.

### 2.19 Review fixes on 0.8.0

Six findings from independent review, all reproduced before being fixed.

**The branch timeout was a decoration.** `reading` read stdout to the end, then stderr, and only then
built a deadline. Against a hung `git` the first read never returns; against a chatty one the two
sequential reads deadlock as soon as the pipe nobody is draining fills. `runBounded` now starts the
deadline *before* the child, drains both pipes concurrently via readability handlers, bounds what it
keeps while still reading and discarding the excess, and terminates then kills on expiry. Exercised
with real `/bin/sh` children: hung, hung-with-open-pipes, both-pipes-flooded, output far past the
cap, and a check that the child's pid is gone afterwards.

**A record with no `sessionId` was accepted as ours.** The comment said every record must carry the
id; the code only rejected records carrying a *different* one. Now positive identity or nothing —
for messages and for questions — and no prefix matching.

**Plain-string message bodies were dropped.** `message.content` is sometimes a bare string rather
than a list of typed blocks (observed live). Both are read. Separately, a `user` record is only a
genuine request when it has no `toolUseResult`, is not `isMeta` or a compaction summary, and its
`userType` is external — role alone was letting tool results and injected notices be reported as
"the latest thing you asked for".

**Any matching `tool_result` counted as an answer.** A result marked `is_error` is now `cancelled`.
And a missing result is `notObserved` in every case, including a complete file — the old
"unanswered" verdict inferred a pending request from an absent line, which is precisely the invented
alert this app exists to avoid.

**The command line read first and validated afterwards.** It opened a transcript for any id with a
matching file, printed "not in the tracked queue", and exited 0; `attention.known` was true merely
because `session != nil`. Both are gone. `SessionContextQuery` is now the single path for the command
line *and* the app: identity first (`verifiedLive` / `processGone` / `unverified` / `notTracked`,
with no contents read for the last), then the same `StatusReport` trust model the badge and panel
use. `known` requires a positively-known state *and* a trustworthy queue; a saved ask from a stopped
app is still reported, labelled a record. Queue freshness, app presence, unprocessed hook events and
the newest message's age are four separate fields. New exit code 5.

**Metadata authority re-verified.** All five live worktree sessions independently confirmed on
`cs/client-info-t1`, `cs/red658-plan-vs-ledger`, `cs/sensitivity-train`, `cs/red645-own-capital`,
`cs/exec-cashflow-truth`; the sixth reports `notARepository`. `redmy-36`, `redmy-6e`, `redmy-0c` and
`redmy-e9` are demoted to Details with the worktree as the label.

### 2.20 A session can be linked to its Ghostty tab

Ghostty 1.3.1 exposes `id`, `name` and `working directory` on a terminal, and no pid or tty. The
mapping is therefore not discoverable, and deriving one from cwd or title would send somebody to a
stranger's tab with full confidence. So the user makes it, once per session, and **the confirmation
is the evidence** — recorded as `provenance: userConfirmed`.

**Adapter.** `GhosttyAdapter` speaks four operations: which Ghostty is running, read the selected
terminal (`front window → selected tab → focused terminal`), does this id exist, focus this id. It
is behind `GhosttyControlling`, so every test and `--uicheck` runs against `MockGhostty` and never
against the real application. `input text`, `send key`, `new tab`, `close` and `quit` are all in
Ghostty's dictionary and none is reachable from anywhere in this app. Ids are shape-checked and
AppleScript-escaped; scripts run off the main thread with a deadline.

**Pairing window.** Read → check → confirm, with the session's branch, tty and full id shown beside
the terminal's id, name, directory, tab, window and Ghostty's pid. **Confirm re-reads first**: a tab
that moved, or a Ghostty that restarted, invalidates the preview and writes nothing.

**Store.** `pairings.json`, mode `0600`, its own schema, identifiers and timestamps only. One link
per session; confirming again replaces it. Links for ended sessions are retired in the shared cycle,
which touches the link file and never the queue.

**Validation.** Both ends are pinned to a process incarnation (pid *and* start time). Relaunched
Ghostty, closed tab, changed Claude process, Ghostty not running, permission refused — each refuses,
leaves the item pending, and says how to relink. There is no fallback to another terminal.

**Navigation.** A valid link gives `.exactTab` and the label *Open linked tab*. The activator
focuses the exact id and then **reads back what is focused**; a different terminal, or an unreadable
answer, is not success and does not clear the card. `aa-status` reports the link with its verdict, so
nothing infers exact navigation from an app coming forward.

**Live focus is unverified.** Mocked adapters prove the decisions, not the behaviour. Whether
focusing actually lands is something only the person at the machine can confirm, after they link a
tab and grant the Automation prompt.

### 2.21 The running version, bottom right

`AgentAttentionVersion.string` rendered in the panel's bottom-right corner, read from the same
constant `--version` prints. There is no second copy of the number anywhere, and `--uicheck` asserts
the rendered text equals the runtime value.

### 2.22 One session, one row

The panel drew the same session twice: once as a card in the queue and once as a row in the session
list. The approved layout replaces both with a **single list, keyed by full session id**. Each row
carries the readable name, then either the open request or what that session is actually doing —
never both, and never the same sentence twice (`detailLine` drops a reason that only repeats the
request's own label).

The row **is** the primary action, and the tooltip and VoiceOver label state which action *before*
the click: a linked Ghostty session navigates to its verified tab; an unlinked one opens its recent
conversation, which is where linking is offered; anything else raises what can honestly be raised.
Per-row Open / Details / Snooze / Dismiss buttons are gone. Everything secondary lives in one
always-present `⋯` menu in the same position on every row: recent conversation, link / change /
remove, and — only when there is a notification — snooze and dismiss, with `Details` one level down.

The cap is presentation only: at least eight rows are shown, `+N more tracked` states the rest, and
**Show all N sessions** expands it. Nothing is hidden from the counts, and collapsing never resolves
anything.

### 2.23 Sound is a master switch, and settings tell the truth

The header carries a speaker and a gear. The speaker is `soundEnabled` — muted means **no sound at
all, including speech**, and the config expresses that once as `speechIsAudible = soundEnabled &&
speechEnabled` rather than in each caller. Muting does not clear `speechEnabled`, so unmuting
restores exactly what was already set and turns nothing on that was never asked for; nothing that
happened while muted is announced afterwards, because the queue holds items, not a backlog of
utterances. `AppDelegate.applyConfigChange` applies audio *before* the write, so a mute takes effect
immediately, and the hand-edited-file path goes through the same rule.

The gear edits the same file in the user's words: sound, spoken alerts (disabled while muted, with
the reason stated), which events raise a notification, snooze length, the bubble. Every change goes
through `onSettingChange`, which **returns whether the write actually happened** — a failed save is
reported in the panel instead of appearing to have been applied, and the control keeps showing what
is stored.

### 2.24 The freshness of the list is stated

Bottom left, `updated HH:mm:ss`, taken from the render's own clock. Warden redraws on every hook
event and every sweep, so a timestamp that stops moving is itself the signal. The version stays
bottom right, still read from `AgentAttentionVersion.string`.

### 2.25 One definition of "does this session need me"

`SessionState.attentionCertainty(at:ttl:)` now owns the rule; `StatusReport` and the panel both call
it. They were two copies of the same `switch`, which is a disagreement waiting to happen — the
command line calling a session quiet while the panel called it uncertain, about the same session at
the same moment.

### 2.26 A self-check must not touch a real application

**Found while adding the frontmost-app assertion.** `TerminalActivator.perform` looked the terminal
up with `NSRunningApplication` and called `activate()` on it. With a Ghostty-shaped fixture identity
and a real Ghostty running on the machine, `--uicheck` was bringing the **user's actual Ghostty**
forward — a real window change from a test. It was doing so on this machine during this session's
UI-check runs before the seam existed.

`TerminalAppControlling` now separates the decision from the act: `SystemTerminalApps` in the app,
`InertTerminalApps` in `--uicheck`, which answers "yes, it is running", records the request, and
raises nothing. Every activation assertion runs through it. No Ghostty script call was ever made —
those were mocked throughout — and nothing was closed, quit or restarted.

## 2b. The independent-review correction round (0.10.1)

Six findings from `work/final-review-findings.md` were still present in the final source. Each was
re-checked against the code before it was touched; nothing already corrected was redone.

### 2b.1 One scripting gate for the whole process

**The defect.** The AppleScript queue was `static`, but the "a script is outstanding" flag was
per-instance. Every activation builds its own adapter and the pairing window owns another, so a
second adapter could queue a request *behind* a first one that was blocked. Its caller would give
up at the deadline and report a timeout — and then, when the first script finally returned, the
queued script would run anyway. For a `focus` that is a terminal jumping to a tab minutes after the
click that asked for it.

**The fix.** Scheduling moved out of the adapter into `Core/ScriptExecution.swift`:

- `BoundedScriptRunner` holds **one gate for the whole process**. While any script is outstanding —
  from any adapter — every other request is refused immediately with `.busy` instead of queued.
  Repeated clicks on an unresponsive row cannot stack up navigation;
- the deadline is **re-checked immediately before execution**, so a request that expired while
  waiting to start is dropped unsent;
- the gate is released by the queue block itself, which captures no `self`, so an adapter released
  mid-script cannot strand it;
- every script is wrapped in `with timeout of N seconds`, giving the Apple event the same budget the
  caller has instead of an indefinite one (it then errors -1712, which is already mapped to
  `.timedOut`);
- the executor is injected (`ScriptExecuting`), so all of this is testable without AppleScript.

**What is still true and stated in the code.** An Apple event already delivered cannot be recalled:
if `focus` was sent and the reply is late, the tab may still change afterwards. The guarantee is
narrower and worth having — *no unsent request executes after its deadline*, and nothing is ever
queued behind a blocked script.

### 2b.2 Linked navigation is a fail-closed transaction

**The defect.** `TerminalTarget.plan` appends `.activateApp` after `.ghosttyFocus`. The old loop
appended a problem on a failed focus and carried on, so a refused, timed-out or misdirected focus
still raised Ghostty and reported `appOnly` — the user looking at the wrong tab, told they had
arrived somewhere. And `tabSelected` plus a *failed* frontmost check still became `exactTab` as soon
as `apps.activate` returned `true`, which is a request having been made, not a window being in front.

**The fix.** `focusLinkedTab` handles the whole paired path as a transaction and never falls through
to the generic loop. Any failure — incarnation change, refused focus, timeout, wrong readback,
unconfirmable readback — returns `.failed` immediately with the reason, and **no app is raised**. If
a raise is needed, everything is re-verified *after* it: the Ghostty fingerprint still matches the
pinned one, the focused terminal is still the linked one, the frontmost pid is the pinned pid, and
the session's Claude process is still alive. Only then `.exactTab`.

### 2b.3 A self-check cannot drive the real machine

The previous round found `--uicheck` activating the machine's real Ghostty and fixed it by
injection. One call site still relied on the default controller. Injection is now backed by a brake:
`ActivationSafety.liveActionsForbidden`, set only by `--uicheck`, makes `SystemTerminalApps.activate`,
`runAppleScript` and `runTmux` refuse and record. The check asserts the brake **never fired** — so a
missed injection is a visible finding rather than a silent live action.

### 2b.4 Confirming a link re-checks both parties, after the slow part

`confirm()` probed Claude before the Automation call and took the Ghostty fingerprint before the
read. Now the fingerprint is taken on **both sides** of every read (a Ghostty that restarts mid-read
would otherwise pin a new run's tab id to the old run's fingerprint), Claude is re-probed **after**
the read, and the session is re-validated against the engine's live record through a new
`currentIdentity` provider — a session id reused by a newer Claude process is a different session
wearing the same name.

### 2b.5 The red window button counts as a close

`PairingWindow` is now an `NSWindowDelegate` and invalidates its generation in `windowWillClose`, so
a read or confirm in flight when the title-bar button is pressed cannot come back and save.

### 2b.6 The row shows its branch, and a finished turn is calm

A row with an open request showed no branch at all — exactly when "which worktree is this" matters
most. One short muted line now sits above the request, using the same git-only rule as quiet rows.
And `workComplete` gets its own calm colour: a finished turn is news, not a demand. Styling only —
what raises a notification and what the header counts are untouched.

## 2c. Open session, from the conversation window (0.10.2)

The window that shows a session's recent exchange had only **Refresh** and **Close**: you could read
what a session was doing and still have to go and find its tab by hand. It now carries **Open
session**, using the same validated pairing path a linked row uses.

- **The session is resolved at the click**, from the engine, by full id — never the identity the
  window happened to open with. One that has ended, or been replaced under the same id, is refused
  and said so.
- **Nothing is dismissed or snoozed**, on any outcome. Arriving at a tab is not dealing with what
  the session asked for, and this window does not get to decide that it was.
- **No consolation prize.** No app-only raise, no clipboard, no resume command. Either the linked
  tab is reached — with the existing post-focus identity and foreground proof — or the window says
  what stopped it.
- **No link** routes to the existing "Link Ghostty tab…" window, with the reason stated before the
  click (tooltip and VoiceOver label) and again after it. Linking there makes Open session usable
  immediately, without disturbing the transcript on screen.
- **A stale link** explains itself and leaves the offer to link again standing. (The first version
  of that offer vanished on the next state refresh — caught by the check that asserts it survives.)
- **One request at a time**, and a result that arrives after the window has closed or moved to
  another session is dropped.

`presentPairingWindow(for:)` is now the single place the pairing window is presented from, so both
surfaces share one persistence and validation path.

## 2d. Inactive-window cursor handling (0.10.3; live verification pending)

**Reported again from the running build:** entering the bubble or a row from a text application
still showed an I-beam. The previous fix did not work, and the tests said it did.

**Root cause.** The whole policy hung on `cursorUpdate(with:)`. Apple states that this message is
**not sent** for a tracking area registered with `.activeAlways` — and every area in this app is,
because the bubble and the panel are deliberately never key. `mouseEntered` only recorded
`hovering = true`; the bubble's also refreshed its appearance. So on the one path a user actually
takes — arrive carrying another app's cursor — nothing ever called `set`, and the I-beam stayed.

**Why the tests passed anyway.** They called `cursorUpdate(with:)` directly and asserted the
tracking options, which tested the one message AppKit never delivers here. That is the more useful
finding: the checks were shaped like the implementation instead of like the user's hand.

**The fix**, in four places and nothing more:

- `ClickCursor.trackingOptions` gains `.mouseMoved` and **loses `.cursorUpdate`**. The suppression is
  a property of the option, not of which window is key, so there is no arrangement in this app where
  that message would arrive; leaving the flag in suggested a second mechanism that does not exist.
  The `cursorUpdate(with:)` overrides stay — a correct answer to a message nothing sends here — and
  nothing depends on them;
- `ClickableView`, `ClosureButton` and `BubbleView` set the cursor in `mouseEntered` **and**
  `mouseMoved` — the messages a background window does receive. Movement matters because another
  application can reassert its own cursor while the pointer is still inside ours;
- `ClickCursor.prepare(_:)` sets `acceptsMouseMovedEvents`, and it is applied to **all four**
  windows: the bubble, the panel, the conversation window and the linking window. The first attempt
  prepared only the two borderless ones — but the gear, the speaker, *Open session*, *Refresh*,
  *Read selected tab* and the rest are the same shared controls, which is exactly what the second
  report said. Neither the bubble nor the panel becomes key; nothing polls;
- selectable text is untouched. The transcript and the identity lines keep the I-beam macOS gives
  text, because there they are right.

Release on exit, on disable, on hide and on leaving the window is unchanged.

**The tests now start where the user starts:** `NSCursor.iBeam.set()`, then the enter and move
events. Not for a representative control — for **every visible one**: the bubble, a session row, and
by enumeration the panel's Dismiss all, Sound, Settings, Collapse, disclosure and each row's ⋯, the
conversation window's Open session / Link / Refresh / Close, and the linking window's Unlink / Read
selected tab / Confirm link / Close, plus a disabled control. Eleven checks failed before the first
change; the two window-preparation checks failed before the second — verified by removing each fix
and re-running.

**Still not proven, and stated as such.** No test can show the shape on screen. What is proven is
that the supported entry and movement paths now call `set` with the right cursor, and that the
windows are configured to receive those events. Only looking at the pointer on a live machine can
confirm the fix — computer use was unavailable this turn, so that observation has not been made.

## 2e. The cursor: what is now actually established (0.10.4)

**The second live failure matters more than the first.** 0.10.3 made the handlers run — the hover
highlight proves that — and the tests still said the cursor was right. It was not. So this pass
stopped changing the cursor code and went looking for what the tests could not see.

**Evidence, from Apple's own headers on this machine:**

- `NSCursor.h`: `currentCursor` — *"This isn't necessarily the cursor that is currently being
  displayed, as the system may be showing the cursor for another running application."* Every
  assertion in the suite reads that property. They are statements about this process, not the screen.
- `NSTrackingArea.h`: `NSTrackingActiveAlways` — *"owner receives mouseEntered/Exited or mouseMoved
  regardless of activation. **Not supported for NSTrackingCursorUpdate.**"* This confirms both halves
  of the earlier diagnosis: enter and moved do arrive while inactive, and `cursorUpdate` never does.

**And a direct experiment** (`/tmp/warden-cursor-probe`, an inert accessory app: its own
non-activating panel, never activated, no pointer moved, no event posted, no other application
touched). While another application was frontmost:

```
active application: someone else       frontmost: ChatGPT
panel is key: false, can become key: false
before    app-local: arrow          system: other(28x40)
after set app-local: pointingHand   system: other(28x40)
settled   app-local: pointingHand   system: other(28x40)
```

**What that does and does not show — corrected.** The pointer was **not over the probe's panel**
during that run. So it establishes one thing firmly: `NSCursor.current` changed while the displayed
cursor did not, therefore every app-local assertion in this suite is insufficient as evidence of
what is on screen. It does **not** establish that a non-activating panel can never affect the
visible cursor — setting a cursor with the pointer somewhere else is expected to do nothing, and
that is not the case under test. An earlier draft of this report claimed impossibility and required
activation or private SPI to fix it. That claim was not supported by this experiment and is
withdrawn. The non-focus invariant stands, no private SPI is used, and the cursor stays unresolved.

**The next evidence has to come from a real hover over Agent Warden's own window**, which no test in
this repository can produce.

**What ships instead:** bounded, opt-in diagnostics.

With `AGENT_WARDEN_CURSOR_DIAGNOSTICS=1`, each hover on Agent Warden's own views appends one line to
`cursor-diagnostics.log` (created **0600** in the data directory): time, event kind, view type,
whether the app is active, whether its window is key, and a **shape fingerprint** — size, hot spot
and a hash of the image bits — of both the cursor this app set and the one the system reports, plus
`systemMatchesWanted=yes/no/unknown`. Fingerprints rather than `==`, because comparing singletons
reports a mismatch for visually identical cursors and would send this investigation off again. A nil
system reading is `unknown`, never a match.

An entry also takes **one** delayed sample 250 ms later, discarded if the pointer has already left.
That distinguishes a cursor applied late by the compositor from one that never takes. A single
deferred read: no loop, no timer, no polling — with the pointer elsewhere the log stays silent.

A run is bounded by whichever comes first: **400 records, 64 KiB, or ten minutes**. After that it
writes nothing until the app restarts. No screen contents, keystrokes, transcripts, session text or
anything from another application is recorded, and no image is written — only a hash of one.

**How to run it without touching saved settings** — a temporary Warden-only LaunchAgent, original
preserved, no `launchctl setenv`, no `config.json` edit:

```bash
PLIST=~/Library/LaunchAgents/ai.wundamental.agent-warden.plist
cp "$PLIST" /tmp/warden.plist.orig
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" \
  -c "Add :EnvironmentVariables:AGENT_WARDEN_CURSOR_DIAGNOSTICS string 1" "$PLIST"
launchctl kickstart -k "gui/$UID/ai.wundamental.agent-warden"
# hover the bubble and a row, arriving from a terminal, for about ten seconds
cat "$HOME/Library/Application Support/AgentAttention/cursor-diagnostics.log"
cp /tmp/warden.plist.orig "$PLIST"
launchctl kickstart -k "gui/$UID/ai.wundamental.agent-warden"
```

**The remaining question:** whether a non-activating accessory panel can own the pointer *while the
pointer is over it*. Not measured yet. Until a hover trace answers it, the cursor is **not** claimed
fixed and no further change will be made on a guess.

## 2g. Escape, and where it stops (0.10.4)

Escape closes the conversation window and the linking window, through Cocoa's own cancel path
(`cancelOperation`, plus the key-equivalent path for windows whose responder chain would swallow it).
The event is consumed where it lands, so one Escape closes one window. Menus already do this
themselves. Closing is all it does: nothing is dismissed, snoozed or resolved, no session is stopped,
and an unconfirmed link is not saved — a read or confirm in flight is abandoned, and a closed window
now refuses to act at all.

**The boundary, stated rather than glossed:** this works while you are *in* Agent Warden. Escape
typed into a terminal belongs to the terminal. There is no global key monitor, no event tap, no
Accessibility grant, and no focus is taken to catch a keystroke. The expanded panel is a
non-activating window that never receives key events, so Escape cannot reach it; clicking outside it
still collapses it.

## 2h. Names and branches, told apart (0.10.4)

Five live rows disagreed with each other, and two independent defects were behind it.

**Provenance never arrived.** `fillGaps` copied `titleSource` only when the title itself was missing,
so a name learned from a hook could never acquire its source. Every registry-generated identifier was
therefore indistinguishable from a name a person chose. The source is now filled independently — and
only ever for the *same* name, because a source belongs to the string it describes.

**A rename could never be taken.** "Fill only the gaps" meant a name, once known, was frozen for the
life of the session. `refreshTitle(from:scannedAt:holdingSince:)` takes a newer registry name for
demonstrably the same session on the same process from a scan no older than what we hold — and
touches the title and its source only. It never replaces the working directory or the branch, because
the registry records where a session was *launched*.

**The launch branch masqueraded as the current one.** `branchFact` fell back to the transcript's
`gitBranch`, observed reading `main` for five sessions each on their own `cs/…` branch. It now
returns only a `git` reading, taken in the directory the session is in **now**, and only when that
reading is a statement about the branch (`branch`, `detached`, `notARepository`). A failure to read
is reported through `branchAvailability` (`pending`, `denied`, `timedOut`), and the launch stamp is
kept separately as `launchBranch`, labelled "at launch".

**A branch could also be inherited from a directory the session had left** — `fillGaps` copied any
older `branch`. It now copies one only when its `path` is the current `cwd`. A session that moves to
the project root keeps the reading for where it is, and is not dragged back to its old worktree.

**`aa-status --json` now carries the current branch**: `branch`, `branchAvailability`,
`branchSource`, `branchReadAt`, `branchPath`, plus `titleSource` and `displayName` so a voice client
and the panel cannot disagree about which session is which. `gitBranch` remains, explicitly
deprecated in the schema comment, for existing consumers.

**Limits.** All of this is offline metadata; nothing here queries Ghostty or infers a terminal. If a
live row still shows a name that none of these rules explains, the one thing I would need is that
row's full session id together with its `aa-status --json` entry — the observed defects above are
fixed without it, but a mismatch beyond them cannot be diagnosed from here.

## 2f. A chain beside each session (0.10.4)

A small icon per row, replacing nothing and adding no full-sized control:

- **three states, decided offline** — `SessionLinkState.of(pairing:identity:)` compares the saved
  link's Claude pid and start time against the session's own. No Automation call is made to draw a
  row, so the queue never waits on a terminal: `none` (grey chain), `saved` (green closed chain),
  `stale` (orange chain needing attention);
- **saved is not verified**, and the wording says so: "because you said so… whether that tab is
  still open is only known when opening it lands";
- **click always routes this exact session to the shared pairing window**. It never navigates, never
  dismisses, never snoozes; it is an enabled control, so it keeps its own hit and the row's click
  does not fire behind it;
- it appears only where linking means something — a Ghostty session with the workflow wired — so
  there is never a disabled icon sitting inside a clickable row;
- the row's text columns lost exactly the icon's width; the clipping check confirms nothing was
  squeezed.

`build/qa/panel-links.png` shows all three states together.

## 2i. A turn that hands something back (0.10.5)

**The defect, from a real transcript.** A turn ended with one shell still running *and* a dedicated
footer asking for a decision. The background rule suppressed the generic completion — correctly, on
its own terms — and the request went with it. Then a `SubagentStop` arrived, was classified as
ordinary activity, and marked the parent "working", which closed the wait that should never have
been closed. Nobody was told anything.

**Three changes, each narrow.**

*A request is now its own kind.* `AttentionKind.handoff` — "Waiting for you" — is **not** generic, so
completion evidence does not gate it and background work does not silence it. `Stop` classification
reads `last_assistant_message` (the field Claude Code's hook documentation provides for this, and
recommends over reading the transcript because the final text may not be on disk yet) and looks for
one thing: a *dedicated line* whose own text is `I need from you:` — Markdown emphasis allowed,
because that is how it is written — followed by an actual request.

What deliberately does **not** count: a question mark anywhere; a suggestion in a paragraph; the
phrase inside a sentence (`I need from you to be patient` has no colon and is prose); a line inside a
code fence, a block quote or an indented block; anything over 16 KiB; and — the one that matters most
in practice — `I need from you: nothing`, `none`, `no action`, `nothing — carry on`. Those end most
of these replies, and alerting on them would make the app cry wolf on nearly every turn. A following
space disqualifies the dismissal, so `none of these options work — pick one` is still a request.

*A child stopping is not the parent working.* New `SignalClass.housekeeping`: `SubagentStop` and
`SubagentStart` keep the session's record current and do nothing else — no wait resolved, no pause
superseded, no "working". They spool nothing, exactly like activity, so there is no new file churn.
A subagent's own `last_assistant_message` is never read as the parent asking.

*The installed hooks keep working, with no `settings.json` rewrite.* This mattered more than it
looks: the installed entries pass `Stop --kind workComplete` and `SubagentStop --signal activity`,
and the override used to win outright — which would have vetoed both fixes on every existing
installation. The rule is now that an override still decides, **except** where the payload supports
something more specific about the same event: a *generic* override yields to a real request read
from that payload, and `--signal activity` yields to housekeeping for the events that are
housekeeping. Nothing can make an event less specific, and `--kind approval` is never second-guessed.

**Privacy is unchanged by default.** The final message is parsed in memory. What is stored is the
static reason "Asked you for a decision before it can carry on"; the request's own words reach disk
only if `includeHookMessages` is on, and then only as a ≤120-character excerpt of the request itself.
The smoke test asserts the words are absent from both the card and the state file at the default.

**Review corrections, before install.** An independent pass found four defects in the first cut, all
now fixed and each covered by a test that fails without the fix:

1. **A bare label alerted.** `**I need from you:**` with nothing after it was treated as a request,
   as was a continuation that said `Nothing — all checks passed.` A label is a heading; a request
   needs affirmative text. One line of lookahead past the label is supported (that is a normal way
   to write it), a declining continuation stays quiet, and any shape this parser will not interpret
   — a fence, a quote, another label, text far below — is quiet by choice rather than by guess.
2. **Fences toggled on any fence.** A ` ```` ` block containing `~~~` opened the content early, so a
   code sample became an alert. A fence now records its character and length and is closed only by
   one of the same character and at least the same length; an unclosed fence leaves the rest opaque;
   and a handoff wrapped in inline backticks is read as a quotation of the convention. Parsing is
   bounded by line count as well as bytes.
3. **Housekeeping heartbeats went nowhere.** Housekeeping spools nothing, so the heartbeat is the
   *only* place a subagent's proof of life arrives — and the old path merged identity only for a
   session that already existed and never advanced last-seen. It is now ingested, deduplicated by
   the same deterministic id, so a session first heard of through a child is kept and its last-seen
   moves, while the request, the pause, the activity, the last-activity time and any dismissal are
   left exactly as they were.
4. **Records already on disk still said `activity` for `SubagentStop`.** Replaying one could close a
   request the parent had just made. A known child-lifecycle event is now read as housekeeping at
   the single ingestion boundary every record passes through — spool and heartbeat alike — while a
   genuine `PostToolUse` or `UserPromptSubmit` resumes the turn exactly as before.

A second pass found two more false positives, also fixed:

5. **A complete no-request phrase still alerted.** `no action needed.` and `nothing required.` were
   read as requests, because the check demanded punctuation immediately after the phrase. A closed,
   explicit list of endings — needed, required, necessary, further, else, more, at all, for now… —
   may now finish one, chained at most three deep. It is a fixed list, not language understanding:
   `none of these options work, please choose` contains `of`, which is not on it, and stays a request.
6. **A fence with an info string closed the block.** ` ```python ` inside a ` ```text ` block ended
   it early, so the sample's own lines were read as prose. An opening fence may carry an info string;
   a closing one may carry nothing but whitespace after its delimiter. A genuine footer after a
   properly closed block is still read.

Codex's independent fixture (`work/check-handoff-policy.py`, external to this repository, now 16
cases) reproduced five of these six and passes 16/16 against the release build.

**The already-missed request is not recovered, and here is why.** Nothing was injected: no synthetic
event, no mutation of a user session, and `aa-status`/`--context` remain read-only. A safe recovery
is possible in principle — an **app-owned startup reconciliation**: for each tracked session whose
process identity still verifies exactly, read the transcript tail *once* at launch, and raise a
handoff only if the last assistant turn carries the marker **and** no later user turn or activity
event exists for that session. That needs strict turn ordering and a verified full-session/process
match to avoid resurrecting anything answered offline, and it is a transcript read — the thing this
app has deliberately kept on-demand-only. It is a genuine architectural addition, not a tweak, so it
is **proposed, not built**; the hook fix above stops it happening again from now on.

## 2j. The session bridge (0.11.0)

A local interface for driving Claude Code sessions **Agent Warden started itself** — the first
increment of the approved communication bridge, and the first thing in this app that *acts* rather
than observes.

`aa-bridge serve` owns a Unix socket (0600, in the user's own data directory — no port, no token) and
the sessions it starts. `start` launches a new official client with the documented streaming
interface; `send` gives it a turn; `status`, `events` and `stop` do the obvious. Every answer is JSON
and every refusal names the rule that refused it.

**The distinctions that make it usable.** Accepted (written to a pipe) is not acknowledged; the
client's own echo of our message is. Acknowledged is not active; active is not a result; and a client
that goes away or misses a deadline leaves the turn **uncertain** — never resent, because an
ambiguous retry is how one instruction becomes two.

**Owned sessions only, structurally.** Session ids are generated by the host and cannot be supplied
by a caller, so this interface cannot be pointed at a session someone has open in a terminal. Those
remain observed and undriven.

### Corrections after the first review

The first cut deadlocked before a single session was created. An independent pass listed the causes;
each is fixed, and each has a test:

| Finding | Fix |
|---|---|
| Accept loop and connection handling shared one serial queue — **no client was ever served** | Separate accept queue; a bounded concurrent pool for connections |
| Binding `unlink`ed whatever was at the path, including a caller's file or a live host's socket | A regular file is refused outright; a live socket is refused; only a dead socket of our own kind is replaced, and `stop` unlinks only if the inode is still ours |
| SIGTERM handlers were released immediately, leaving the signal ignored with no handler | Sources held for the process's life; shutdown stops owned children and *confirms* they went |
| Any user echo acknowledged the first pending message | A correlation id is written into each message and required back, with the text, before anything is acknowledged; duplicates count once |
| A result completed every incomplete message | One turn in flight per session; a second send is refused as `busy`; a result settles that turn and nothing else |
| A failed write left no tombstone, so a retry could send twice | Intent is recorded *before* the write; a failed write leaves the turn uncertain and burns the id |
| Reusing a start id with different intent returned the old session | The whole intent is fingerprinted; a different directory or model under the same id is a conflict |
| Approved roots compared unresolved paths | Roots and requests are resolved through symlinks; an escaping link is refused |
| Locks held across blocking writes; a stop during launch could leak a process | I/O happens outside the lock; a stop that arrives mid-launch terminates the process that appears |
| Deadlines anchored to the previous turn's activity | Anchored to the turn itself, so a fresh turn is not born overdue and stray frames cannot postpone a timeout |
| Partial writes, unbounded frames, oversized-line suffixes read as frames | Full-write loops, per-socket deadlines, `SIGPIPE` off, oversized input discarded to the newline, responses paged with a cursor |
| Launcher missing `--verbose`; permissions implicit; exit classified before stdout drained | `--verbose` and `--permission-prompts none` are explicit, `--dangerously-skip-permissions` is unreachable; exit waits (bounded) for stdout EOF; bounded stderr is kept as failure evidence |
| CLI structured failures exited 0; `--version` unreachable | Exit 0 done, 3 refused, 4 unknown; `--version` handled first |

Codex's independent socket fixture (`work/check-bridge-socket.py`, outside this repository) covers
the three that could be reproduced without Claude, and passes 3/3 against the release binary.

### Second review round — five failing regressions, and the rest of that list

An independent probe found five more, each reproducible. All are fixed, and each has a product test:

| Probe case | What was wrong | Fix |
|---|---|---|
| `uncertain turn cannot be overtaken` | A timeout or failed write **released** the turn, so a new send could go out and the old client's late answer would land on it | An unresolved turn keeps owning the session. New sends are refused (`busy`) until a result, an exit or a stop resolves it |
| `unattributed result cannot complete` | A frame with no `session_id` was accepted | Attributable frames (`user`, `assistant`, `result`) must carry this session's id exactly; the client-reported id is pinned only after validation |
| `changed echo text cannot acknowledge` | Acknowledgement matched *contains(correlation)* | The echo must be a user-role, text-only message whose whole body equals what was sent. Tool results and edited copies acknowledge nothing |
| `fast result is not reverted to accepted` | The phase was written **after** the write, overwriting a completion the client delivered during it | The phase is set before the write and never written back afterwards |
| `event response fits protocol byte cap` | 100 × 4 000 characters exceeded the frame limit — reported as success, lost at the reader | Every response is paged by **encoded bytes**, including status-for-all-sessions; omitted messages are stated (`messagesOmitted`), the cursor always advances, and an answer that still will not fit is refused rather than sent |

The remainder of the same review, also fixed: process lifecycle now follows the real process
(`isRunning`), so shutdown cannot report success while a child is up; writes to the client are
non-blocking with a deadline, so a full pipe is an ambiguous send rather than a hang, and cleanup
never stalls behind one; the line buffer bounds each line **while scanning** and discards an
oversized one through its newline; digests are SHA-256 over a stable serialisation, replacing a
per-process `Hasher` value that was formatted to look 64-bit wide; results require the documented
`is_error` field, so a missing one is not read as success; and traffic arriving after a stop settles
nothing. The socket now requires a canonical parent directory this user owns with no access for
anyone else, refuses symlinks and foreign endpoints, replaces a stale socket only on a definite
`ECONNREFUSED`, checks the result of `chmod`, and verifies the peer's uid on both sides.

`aa-bridge` is bundled into the app by `Scripts/build-app.sh`. The app does **not** host or start
it: a host runs only when a person runs one, with directories they name explicitly.

### The live proof

One disposable session, run **once** (session `46A64949-…`, artifacts preserved): `AGENT_WARDEN_LIVE_BRIDGE=1 ./Scripts/bridge-live-check.sh`.
It creates a scratch directory with its own `CLAUDE.md`, starts a host approving only that directory
with tools and MCP servers switched off, starts one session, sends two harmless prompts, and stops
what it started. 15/15, including:

- `clientReportedSessionID` **equals** the id this host generated — compared as a field, not found
  by searching the document for an id we already knew;
- turn one acknowledged by the client's echo of our own correlated message;
- the scratch project's marker in the result **correlated to turn one** — the project's instructions
  reached the client;
- a random nonce, given only in turn one and absent from `CLAUDE.md`, repeated in the result
  **correlated to turn two** — the same conversation, not a fresh one.

Sanitised evidence (both secrets replaced by their names) is in `build/qa/bridge-live/`.

### What is still not built, stated plainly

- **No channel into an existing terminal session.** Claude Code channels require opt-in when that
  session starts, and a custom channel needs a preview flag and local consent. Nothing here enables,
  restarts or injects into a session already running.
- **No voice wakeup.** Local bridge events do not reach a ChatGPT voice conversation. No supported
  third-party injection endpoint has been established, and none is simulated here.
- **No orchestration of the four terminal sessions.** This increment proves owned-session
  communication only. Driving the sessions already open remains unavailable.

### Third review round (0.11.0) — one answer, one turn; one descriptor, one writer

Two defects survived the second round. Both are the same species: something that looks like
evidence, used as if it were.

**A replayed result settled a turn it never belonged to.** A `result` frame carries no turn of its
own, and `session_id` names the *conversation* — it cannot say which prompt an answer is for. So an
old, well-formed, correctly-attributed result arriving after the next prompt had gone out marked
that new turn complete with the previous turn's answer. Three checks now stand between a result and
an outcome:

| Check | Why it is not optional |
|---|---|
| `is_error` present (unchanged) | "no error was mentioned" is not "it worked" |
| Its own identity — the documented `uuid`, else a digest of the outcome-bearing fields — not seen before in this session, bounded to the last 64 | the same answer cannot settle two different turns |
| For a **success**, the turn must have been acknowledged by the client's exact echo | claiming an outcome for a prompt we cannot show it received is a guess wearing a result's clothes |

A **failure** is deliberately allowed through without an echo: a client that dies on the way in
reports its error before any replay, and refusing to record that would leave the session owned by a
turn that could never resolve. Fail-closed does not mean fail-silent.

**A file descriptor was borrowed past its own lifetime.** `write` read the raw descriptor number out
of the `FileHandle` and then looped on it outside any lock, while `terminate` closed that same
handle on another queue. A descriptor is a small integer the kernel reuses the instant it is free —
so the loop could carry on writing an old prompt into whatever pipe or socket opened next. That is
not a crash; it is a success, against the wrong thing.

`DescriptorGate` now owns it. The descriptor is *borrowed* under a lock held for the whole write,
and the close takes the same lock, so the number cannot be recycled underneath a writer. A second,
short lock carries the flags, so `terminate` can say "stop" **during** a write: the signal is
immediate, the writer notices within a poll and hands the descriptor back, and only then does the
close happen — off the caller's thread, so cleanup never queues behind a pipe nobody is reading. The
5 s write deadline and the 3 s grace before this process's own pid is force-killed are unchanged.
`fcntl` is checked rather than hoped for: a pipe that cannot be made non-blocking makes the launch
**fail**, because a blocking write to a client that stopped reading never returns, and one stuck
prompt would become a stuck host.

**Two lifecycle claims separated.**

- A client can exit before `launch` even returns. The handle is no longer installed over a recorded
  exit — a live client held for a dead process would keep `hasRunningClients` true for ever.
- `stop` answers **`stopping`** while the client is still up, and `stopped` only once its exit has
  been seen. A stop that arrives mid-launch now *keeps* the handle, so the exit can be observed
  rather than assumed.

Nine new regressions cover these, including the replay-after-a-second-acknowledgement case, a
deterministic descriptor-ownership race with no process at all, and two inert `/bin/sleep` children
that never read their input — no Claude client is launched anywhere in the suite.

---

## 2k. A sound of its own (0.11.1)

Until now "Sound" only ever meant *not muted*. The master switch gated `SpeechAnnouncer`, and with
speech off — which is the default — there was nothing behind it. This adds the thing the switch was
always implying, and says so where it was misleading.

**The sound is generated, not shipped.** `AttentionChime` produces two sine notes, A5 then E6 — a
rising fifth, which reads as a question rather than a verdict — each 160 ms with an 8 ms attack and
an exponential decay, 50 ms of silence between them. About 0.37 s, peak 0.22 of full scale. A
bundled track would mean a licence question and a binary nobody can diff; arithmetic means the
length, the loudness and the shape of the waveform are all *assertions*. It is encoded as a 16-bit
mono WAV in memory and played through `NSSound`: no audio session, no hardware configuration, no
permission prompt, nothing recorded, nothing fetched.

**Off by default, including for an existing install.** `chimeEnabled` defaults to `false` and an
older `config.json` has no such key, which reads as off. Updating never starts making noise on
somebody's machine. Loading a config still never rewrites it — there is a test that reads a
hand-spaced file with an unknown key and compares the bytes afterwards.

**What may sound, and what may not.**

| Sounds | Silent |
|---|---|
| question, stage decision, approval, handoff, error — and only from an explicit hook | work complete, idle prompt, suspected stall, anything inferred |

Plus four rules that decide the rest:

- **Silence is not a backlog.** While muted or switched off nothing plays *and nothing is kept*.
  Unmuting, enabling or relaunching announces none of it.
- **Only what survived the cycle.** An ask raised and resolved in the same pass makes no sound — a
  sound you get up for and find nothing behind is worse than no sound.
- **One sound per waiting episode.** A session that reports a question and then a permission while
  still waiting is one wait, not two.
- **A four-second floor.** Four sessions finishing together is a chime, not a chord.

**Where the user controls it.** Settings → *Attention chime* (disabled while muted, and the choice
is remembered), *Preview chime* (plays once, on the click, changes no preference, refused while
muted), and the menu-bar item has the same toggle. The master control's help text now names what it
gates, and when sound is on with neither chime nor speech set the menu says so outright: *No alert
sound is on — turn on Attention chime to hear one.*

**No test makes a noise.** Everything asks a `ChimeSounding` recorder instead of a speaker — 33 core
tests over the waveform, the WAV, the policy and the scheduler, and 12 UI-check assertions over the
controls. The only real sound this feature can make is a preview the user clicks themselves.

### Also in 0.11.1 — two bridge follow-ups and the permission mode

- **Result identities are kept for the whole life of a session.** The bound was 64 while a session
  accepts 200 turns, so an old answer could be *forgotten while prompts were still being accepted*
  and then come back to settle a later turn. Retention is now tied to the message bound, with a
  regression that completes 100 turns, acknowledges turn 101, replays turn 1's answer and expects
  turn 101 to still be outstanding.
- **Nothing is launched before there is a way to talk to it.** The bounded `ProcessHandle` is now
  constructed *before* `process.run()`. Bounding the input can fail, and doing it afterwards meant a
  child was already running when it did — leaving a process to be signalled and hoped about.
- **`--permission-mode auto`, stated explicitly.** The mode a session runs under is now a property
  of the launcher rather than whatever the default happens to be, alongside the unchanged
  `--permission-prompts none`. The whole argument list is built by one function so a test can read
  it: the regression asserts the exact vector and that no bypass or skip flag appears anywhere.

---

## 2l. The orchestration contract (0.12.0)

One document, wherever the user keeps it, holding the working agreement. Agent Warden stores a path
and reads that file on request. **No hardcoded location, no assumed note-taking app, nothing
created.** A default path would have been a guess about somebody else's filing, and a wrong guess
that writes is worse than no feature.

**The reader is where the care went** (`OrchestrationContract`). Every request re-reads the
configuration *and* the file: a consumer acting on a cached agreement is the failure this exists to
prevent, so there is no cache here to go stale. The sequence is deliberate —

1. Refuse anything that is not a local path — a `scheme://` location, or a value containing shell
   punctuation. A selection names a file; nothing here fetches or runs anything.
2. `open` with `O_NONBLOCK`, **before** deciding anything. A named pipe with no writer blocks for
   ever on `open` alone, so the descriptor is acquired in a way that cannot wait and *then* asked
   what it is.
3. `fstat` the descriptor: regular files only. A directory, socket, device or FIFO is refused.
4. Refuse by type: an executable bit, or an extension a machine may run (`.command`, `.sh`, `.js`,
   `.html`, `.app`, …). Supported: `.md`, `.markdown`, `.mdown`, `.txt`, `.text`, or none.
5. Refuse over 256 KiB — with the size reported and **no partial body**. Half an agreement read as
   though it were whole is the failure mode worth designing against.
6. Read it all, then `fstat` the same descriptor again and compare device, inode, size and
   modification time against the values the read started from. A mismatch is reported as
   `changedWhileReading` rather than resolved by guessing which half was right.
7. Decode as UTF-8 or say it is not text. Nothing is lossily converted.

`revision` is a SHA-256 of the exact bytes, because a size and a timestamp both survive an edit that
swaps one word for another of equal length within the same second — there is a regression for
precisely that.

**Ten availability states, each distinct**, because `noSelection`, `missing` and `configUnreadable`
ask for three different responses from a consumer and rounding them together loses the difference. A
missing file **stays selected**: a document that is temporarily gone is not a decision to stop
having one.

**The CLI.** `aa-status --contract [--json] [--content]`. Independent of the app and the bridge,
read-only in the strongest sense — no window, no application launch, no execution, no write to the
document or the configuration, no session, no permission. Metadata never carries the body; `--content`
is the only way to get it. Six exit codes, so a script can tell "none selected" from "unreadable".

**The window** (Settings → *Orchestration contract…*). Choose with the normal chooser, paste a path,
clear, reveal in the Finder, open for editing. It re-reads on every action, so what it shows is what
is true now. Cancel, Escape and Close are safe because nothing is written except by a button that
says it writes, and a failed write is shown rather than swallowed.

**Opening is the sharpest edge, and is handled as one.** *Open for editing* is enabled only for a
reading that already came back `available` — so regular, non-executable, supported, UTF-8, bounded,
all proved before any application is involved. The chooser's file filter is a convenience for the
person picking; it is never the check. And the file is handed to a **text editor resolved for the
plain-text content type** — TextEdit, or whatever handles plain text — rather than to the file's own
association, so there is no path from selecting a document to running a program.

**What selecting does not do**, stated in the window and in the README: it is not an authorisation,
creates no permission, and makes no assistant, voice task or tool load or follow anything. There is
no MCP server, no automatic loading, no wakeup. The documented consumer step is explicit: query the
contract, inspect `availability` and `revision`, read the content if needed, act within what you are
actually allowed to do, and ask again when the work or the revision changes.

**Deliberately not built:** no watcher, no rule engine, no model in the loop, no remote sync.

**Verification** — disposable fixtures only, and no real agreement was created or chosen. 25 core
tests (every state, same-size edit, replacement, deletion and restore, binary, oversize, boundary,
FIFO-must-not-hang, network and shell-shaped selections, config re-read, unreadable config, persist
and clear, byte-for-byte immutability), 18 UI-check assertions through an **inert** opener and
chooser (no application launched, no panel presented), and 13 smoke-test checks against the release
binary. The installed selection is left **unset**.

---

## 2m. Readable on its own terms (0.12.0)

The panel was an `NSVisualEffectView` with `.hudWindow` and `.behindWindow` blending, over a
transparent window. That means the surface every label sits on was **partly whatever was behind the
window** — so over a white page the plate lightened, and light-grey supporting text at 0.82 white
lost most of its contrast. The user reported it as very hard to read over light backgrounds, which
is exactly what that arrangement produces.

**The fix is small and boring on purpose.** The window stays transparent, because that is what makes
the corners round and lets the shadow fall outside them; what the text sits on is now an opaque
graphite plate at sRGB 0.13. The bubble goes from alpha 0.94/0.96 to fully opaque. Both windows pin
`appearance` to `darkAqua`, so a system switch to Light cannot resolve a semantic colour into
near-black on a dark plate, and the colours drawn on the plate are stated in sRGB rather than
inherited from the system. No redesign: same geometry, same non-activating floating behaviour, same
clicks, hover, cursor policy and actions.

One real defect fell out of measuring rather than assuming: the badge count was **white on system
orange, 2.1 : 1** — under the 3 : 1 floor. The badge is now a stated amber with dark text on it,
8.8 : 1. `systemOrange` was also a dynamic colour, so its contrast depended on a system preference.

**The check measures; it does not assert intentions.** `--uicheck --readability <dir>` renders the
panel and the bubble, composites each over white, near-black and a busy pattern, and then:

| Measured | Result |
|---|---|
| interior pixels identical across all three backdrops | plate sRGB 0.129, bubble 0.161, alpha 1.00 |
| the corner shows each backdrop | white 1.000 / dark 0.039 — proof the composite is real |
| every plate colour against the plate **as rendered** | 15.1, 13.5, 10.6, 6.8, 6.0, 9.4, 9.7 : 1 (floor 4.5) |
| accent and badge | 7.8 : 1 and 7.0 : 1 (floor 3.0); badge count 8.8 : 1 |
| every colour resolved under Light and under Dark | identical |
| the corners | still transparent, which is what makes them round |

That corner check exists because the first version of this measurement was wrong: the image rep drew
with `copy`, replacing the backdrop, so "identical over three backdrops" was true of a surface over
nothing. Compositing is now stated explicitly and the corner sample proves it.

**These are fixture images**, written to the given directory: this app's own views over backdrops it
invented. Nothing here captures a screen or sees another application, so none of it is evidence
about the live overlay over a real browser window — that remains unproven, and the earlier
foreground capture did not include Warden.

### Also — the contract review's second round

All seven findings, each with a regression:

1. The configuration is read with the same discipline as the document — non-blocking, regular file,
   bounded. A named pipe left at that path no longer hangs the query. `noSelection` now requires a
   definite `ENOENT`; and a `orchestrationContractPath` that is present but is not a string is
   `configUnreadable`, where the tolerant decoder would have turned it into "nothing selected". The
   monitor's own tolerant startup is unchanged.
2. `lstat` errors are told apart: `ENOENT`/`ENOTDIR` is missing, `EACCES` and the rest are
   unreadable. "I cannot look" is not evidence the agreement was deleted.
3. Relative paths are refused with a reason. The same stored selection must not mean one file from
   the app and another from a shell. A second pass closed the gap underneath that: the check ran on
   a trimmed copy while the *original* string was expanded and opened, so a leading space carried a
   relative path straight through, and `~nosuchuser/Agreement.md` — which `expandingTildeInPath`
   leaves exactly as written — was reported as `missing` rather than refused. There is now one
   normalisation: trim, expand, require a leading `/`, and hand that same string on. Nothing
   downstream ever sees the raw selection again.
4. Valid UTF-8 full of NULs and control bytes is data, not a document, and is refused with no body.
   Tabs, newlines and every ordinary Unicode character stay welcome.
5. After reading, both the descriptor **and the path** are re-checked: an atomic replacement or a
   symlink retarget leaves the open descriptor perfectly intact while the selection now names
   something else. Reported as `changedWhileReading` with no body and no revision, and tested
   through a deterministic mid-read seam rather than a racing loop.
6. A selection that fails to save no longer lingers in memory. `ContractSelection.store` builds a
   candidate, writes it, and only then hands it back — so on failure there is nothing to roll back,
   and a later unrelated settings save cannot write out a choice the user was told had failed.
7. Opening reports what actually happened. `NSWorkspace.open` is asynchronous; the window now says
   "Opening…", waits for the completion handler, and reports the error if there is one — guarded by
   a generation counter so a late answer about a document that is no longer selected is ignored.
   The titlebar close invalidates that guard too: `windowWillClose` only cleared the label, so an
   open still in flight could come back after the window was reopened on the same selection and
   write "Opened in a text editor" over whatever it was saying then.

---

## 2n. Background activity, told apart from everything else (0.13.0)

The app knew *how many* things were running behind a turn. It did not know **which**, could not
tell a one-shot shell from a monitor that stays up all day, and folded that knowledge into the same
field as "did the turn finish". This separates the three questions a session raises and keeps them
separate: what the parent turn is doing, what it is **asking** for, and what is running behind it.

**The registry.** `BackgroundRegistry` holds one `BackgroundJob` per identity, and the identity is
**session id plus task id** — never a task id alone, because two sessions can each be running a
`T1` and one session's outcome must not close another's work. Each job carries its kind (finite,
monitor, recurring wakeup, unknown), its state (running, completed, failed, **stopped**, unknown),
its source (snapshot or stream), an optional tool-use correlation, and its **own** observation time,
so freshness is per job rather than per session.

**What it refuses to conclude.** There is no `complete` coverage in practice: `provesNothingIsRunning`
is false for every registry this can build. A stream can drop frames, a reconnect can miss them, an
older client emits none, and a snapshot is a photograph of one moment — so an empty registry is
"we have not heard", never "there is nothing". Whole-goal completion is never read off it.

| Rule | Behaviour |
|---|---|
| wrong session id | refused; no job created |
| no task id | not recorded at all — a job that can never be resolved would sit there looking like work |
| duplicate event uuid | applied once; the clock does not move |
| progress after an outcome | refused as out of order; terminal states are sticky |
| a stated status we cannot read | `unknown`, and coverage drops to partial — not "still running" |
| `local_bash` | `unknown` kind: the same type covers a shell and a monitor |
| over 64 jobs | oldest evicted, count reported, coverage partial |

**The Stop snapshot is enriched, not extended.** Records now keep the entry's id, its type, its
status and — for a scheduled wakeup — whether it recurs. `command`, `description` and `prompt` are
still never read; a test encodes the evidence and asserts none of that text survives. A repeated id
makes the whole reading `unknown`, an unnamed entry makes coverage partial, and a snapshot written
before records existed decodes to `unknown` coverage rather than to an empty list of jobs.

**In the owned bridge**, `task_started` / `task_progress` / `task_notification` / `tool_progress`
are reduced through the same registry, validated by exact session id and deduplicated by the
client's own event uuid. They never settle a turn. Assistant output arriving with no turn in flight
is now recorded as **autonomous parent activity** with its own timestamp, rather than an unexplained
note — and it still opens no turn, so a result from that stretch cannot land on a prompt sent
afterwards. The acknowledgement gate from 0.11.x is unchanged and is what makes that hold.

**At dispatch**, `AlertDispatch.shouldDispatch` rechecks the queued alert against the session's
*current* episode. A generic milestone — "the turn finished" — is cancelled once the session has
resumed work, because it is no longer true. A genuine ask is **not**: a background job reporting
progress does not answer a question put to a person, and cancelling on unrelated movement is how a
day-long monitor silently swallows every question a session asks.

**One real defect fixed in reporting.** `confirmedComplete` was true of any clean `Stop` reading,
however old and whether or not the session had since carried on — a historical observation reading
as current certainty. It now requires the reading to be fresh **and** unsuperseded, and
`observationOnly` says when a reading is being shown as history.

**In the UI**, a third compact line sits under the request: "2 background jobs, 1 a monitor", or "1
monitor running". Details carries one line per job — identifier, kind, state, age — plus the
coverage word and any eviction count, so the list never reads as an inventory.

**Verification.** 672 tests / 49 suites, of which 43 are new and written first: identity and
ownership, duplicates, out-of-order terminals, unknown status, eviction and overflow, monitor versus
shell, snapshot conflicts and older payloads, a blocker surviving child progress, autonomous
resumption, a late autonomous result against a later prompt, and delayed-alert cancellation. Plus 7
UI-check assertions over the compact line, the per-job details, and the absence of any command or
prompt text.

**Limits, stated.** Actual emission of the lifecycle stream by the installed client is **not**
verified here — documentation is not an acceptance result, and no disposable task or monitor was
run. Until Codex's installed test, stream coverage is `unknown` for every session, and older clients
will stay that way. `local_bash` remains undecidable. Nothing infers a job from a process name, and
no process scan was added.

### Corrections after review, against the published typings (0.13.0)

The first cut of this parsed a **shape no client sends**. The SDK's task bookends are
`{"type":"system","subtype":"task_started" | "task_progress" | "task_notification" |
"task_updated"}`; only `tool_progress` carries its name at the top level. My reducer read a
flattened `type`, and my own tests used the same invention — so they would have stayed green for
ever while every real frame fell through to a note. Read against
`@anthropic-ai/claude-agent-sdk@0.3.260/sdk.d.ts` and rewritten, with a regression that the flat
shape is **refused** and full documented frames — content fields and all — in every fixture.

| Finding | What it is now |
|---|---|
| `shell`/`subagent` read as finite | **unknown**. `shell` covers `ls` and `tail -f`; a feature name is not a promise about lifespan. Only a type naming watching behaviour, or a recurring wakeup, decides it |
| `recurring: false` | a one-shot wakeup (`finite`), not a monitor running all day |
| task and cron id spaces merged | identity carries a **namespace**, so a cron's outcome cannot close a shell |
| snapshot overwrote newer stream state | a snapshot older than what we have is refused and coverage drops to partial; a snapshot contradicting a settled outcome is recorded as a contradiction rather than obeyed |
| `source` never updated | it follows the newest evidence, so a reader can see how current a job is |
| only `taskID` bounded | every untrusted string — session id, event id, tool-use id, type word — goes through the same bounds, on the wire **and** off disk. A persisted registry is re-validated: duplicate identities and unnamed sessions are dropped and counted |
| a job vanishing | `background_tasks_changed` is applied with **replace** semantics as the SDK requires; a job no longer in the live set becomes **absent** — not running, and never inferred completed. A client restart resets the set, because the level signal is per-process |
| ambient housekeeping | kept, and excluded from what a person is shown, as the SDK asks |

**Result correlation now uses the documented join keys.** Every prompt goes out with a client
`uuid` on the stream-json user frame; the client stamps it back as `user_message_uuid` and, for a
merged batch, in `user_message_uuids`. A result naming a different send does not settle ours. When
a producer sends **no** join key at all and the session has also been working autonomously, the
result is reported **uncertain** rather than credited to whatever turn happens to be in flight —
unprovable attribution stays unproven. Older producers with no autonomous work in the picture still
settle through the unchanged exact-echo path.

### Acceptance checkpoints (0.13.0)

A handoff that asks the **user** to try something is a different kind of wait, and it is now marked
as one. "UAT steps are here", "please test the new flow", "review the changed screens and confirm"
— requests whether or not they end in a question mark.

Nothing the agent does next satisfies one. A shell finishing, a monitor ticking, a subagent
reporting in, the parent carrying on by itself: none of it is a person having looked at the work.
The engine keeps the item — and keeps it *attached*, so no duplicate is raised beside it — through
every one of those, and closes it only on `UserPromptSubmit` (the user typed back) or an explicit
dismissal. Ordinary waits are untouched: they still close when the session resumes work.

Detection is on the footer the parser already isolates, never by scanning prose. Reports of testing
already done and testing planned for later are both refused, as are quoted and fenced examples — a
false checkpoint is worse than a missed one, because it never goes away by itself. The row says
"Waiting for you to test it" rather than "Waiting for you", because those are different next steps.

---

## 2o. Blocking review findings, fixed (0.13.0)

Two independent checks failed the previous candidate. Both were right, and both were the same
mistake in different clothes: a gap in the evidence being filled in with the convenient answer.

**A synthetic result could settle a prompt somebody typed.** `user_message_uuid: null` is not the
silence of an older client — it is a producer that *supports* the key saying this turn has no client
uuid, which is what a scheduled or background turn looks like. My guard only fired when an assistant
frame had already been seen, so a result that arrived without one landed on whatever was in flight.
Join keys are now read as three distinct answers:

| Frame says | Meaning | Behaviour |
|---|---|---|
| usable key(s) | it names a send | settles ours only if our uuid is in the set |
| the field is there but null, malformed, or the list disagrees with the single value | a turn nobody here submitted | **never** settles a prompt — failures included, because a misattributed failure is still a misattribution |
| the field is absent entirely | possibly an older client | settles only when nothing else suggests concurrency: no autonomous activity, no background jobs, and this client has never stamped a key before |

The replay echo carrying our uuid is deliberately *not* treated as proof the client stamps keys —
every producer replays the frame we wrote, including ones that never stamp a result. Only a reply
frame carrying the field proves support.

**Acceptance handoffs are written as ordinary sentences.** The previous cut only recognised requests
isolated by an `I need from you:` footer, and said so as a design decision. The user's own examples —
"UAT steps are here", "please test the updated functionality" — carry no footer, so seven of ten
independent cases failed. Recognition now runs on the final message itself, and is bounded rather
than broad:

- **Per sentence**, never per message. "The automated tests passed. Please test the UI yourself." is
  a current request; suppressing it because *passed* appears elsewhere is how the ask gets lost.
- Fenced blocks and quoted lines are skipped, exactly as the footer parser skips them.
- Sentences anchored to the past ("yesterday", "I asked you", "you accepted"), to the future ("I
  will provide", "once merged"), or negated ("no UAT is required") are refused.
- Nothing else is read out of the message: no summarising, no topic detection, no scanning for
  questions in prose.

**The owned API states the same three things the monitored sessions do.** It previously offered a
phase, a permission note and a timestamp, which is not parent state.

- `parent` — what the *session* says it is doing (`working` / `idle` / `requiresAction` /
  `unknown`), when it said so, its age, whether that is stale, and whether the client is still
  running. Never inferred: a running job is not a parent state.
- `attention` — an open acceptance checkpoint raised by the session's own words, with the message id
  it belongs to and a bounded excerpt. A task finishing does not close it; the caller sending the
  next prompt does.
- `jobs[]` — now with `namespace`, `recurring`, `ambient`, `ageSeconds` and `stale`, so a consumer
  reads freshness rather than inferring it from a timestamp and a TTL it would have to know. Plus
  `jobsOmitted` beside `jobCoverage`.
- **A client that has gone marks every row stale**, whatever its age, and reports `parent.state` as
  `unknown`. A dead process is not running anything now.

`background_tasks_changed` is applied on the owned stream with replace semantics — including the
empty payload, where a job leaving the set becomes **absent** rather than completed — and ambient
housekeeping is carried but kept out of the work counts.

**Verified:** the two external scripts pass unmodified (independent probe 6/6 from a byte-identical
copy; UAT check 12/12 against the release binaries), plus 20 new product regressions covering
stated-null and malformed keys, contradictory list/single values, keyless results after background
evidence with no assistant frame, older-client compatibility, standalone and mixed UAT prose, and
every new API field.

---

## 2p. Second review round, and the first live evidence (0.13.0)

A read-only review of the candidate found five defects; a Claude-owned review of the fixes found six
more. Both rounds were right, and every one of them was a gap being filled with the convenient
answer rather than the true one.

**Round one.**

| Defect | Why it mattered | Fix |
|---|---|---|
| acceptance detection matched substrings | "the sit**uat**ion is resolved" and "the endpoint **accept**s JSON" became sticky checkpoints nobody could clear | word-boundary phrase matching, **plus** a required address to the reader (please / you / an opening imperative / "steps are here") |
| acceptance raised before validation | replaying an old hand-back reopened the ask against a later prompt, even though `complete()` rejected the frame | raised only after identity, dedup and join-key validation, and never from a replayed frame |
| evidence recorded after early returns | a keyed result arriving between turns did not record that the client stamps join keys, so a later keyless replay took the older-client path | identity, join-key support and autonomous evidence are recorded **before** any return; a key naming another send still proves support |
| membership coerced to empty | a missing or malformed `tasks` array, or one with no session id, marked every known job absent | requires a matching session id and a fully readable array; anything else keeps membership and marks coverage partial |
| merge dropped the acceptance flag | a second signal folding into the episode turned a checkpoint back into an ordinary wait that the next tool call cleared | the flag is sticky through a merge |

**Round two — the checkpoint could still be lost three ways, and two more substring misfires.**

- **Age expired it.** The sweep dropped any item older than eight hours without consulting
  `awaitsUserAcceptance`. An ask put to a person does not answer itself by getting old; acceptance
  items are now exempt from age expiry, and ordinary items still expire exactly as before.
- **A session restarting cleared it.** `applySessionStart` — which `claude --resume` triggers on the
  same session id — resolved the item with the default "the user responded". So did `SessionEnd` and
  the stale/process-gone sweep. All three now say plainly that the *user* did nothing.
- **Half the wordlists were still substrings.** The acceptance words got boundaries; the hand-back
  phrases and the past/future/negation markers did not. "carry**over to you**" invented a
  checkpoint, and "by**passed**" silenced a genuine request. Every list is matched on word
  boundaries now.
- **The live set refreshed a settled job's clock.** `applyMembership` updated `observedAt` for any
  job still listed, including completed ones, reporting a finished job as freshly observed. Settled
  jobs are now left alone and the disagreement is recorded as partial coverage.
- **Result identity without a `uuid`** was raised and *not* changed. The documented frame carries a
  required `uuid`, so a conforming client never reaches the derived path; a producer that omits it
  can collide two identical-text turns, and the second is refused rather than settled. That is the
  safe side: a turn left visibly unresolved can be seen and stopped, an old answer silently settling
  a new prompt cannot.

### Live acceptance on the installed build

One disposable session, in a temporary directory, with only Bash, Monitor, TaskStop and ToolSearch
and an empty MCP config. 12/12, and — more usefully — it settles what documentation could not:

| Observed live | Count |
|---|---|
| `system/task_started` | 2 |
| `system/task_updated` | 2 |
| `system/task_notification` | 2 |
| `system/background_tasks_changed` | 4 |
| tools actually invoked | Bash, Monitor, ToolSearch |

Both jobs reached the API as `completed` from `lifecycleStream`, with coverage `observed` and
explicit freshness. The result **joined to the client's own user-message uuid**, which is the first
real confirmation of the join key this whole correlation design rests on.

**Two limits the run establishes rather than removes.** `session_state_changed` was **not** emitted
by this client, so `parent.state` stayed `unknown` throughout — that path is implemented and
unexercised. And both the background shell **and** the Monitor reported `task_type: local_bash`, so
their kind is `unknown` in the API: the type genuinely does not distinguish them, exactly as
documented.

---

## 3. Files

| New | |
|---|---|
| `Sources/AgentAttentionApp/BubbleMenu.swift` | the bubble's menu, and the single Quit constructor |
| `Sources/AgentAttentionApp/OutsideClickWatcher.swift` | closes the panel on a click outside, observe-only |
| `Core/GitBranchProbe.swift` | read-only branch reading; `runBounded` enforces the deadline and drains both pipes |
| `Core/SessionContextQuery.swift` | the single identity-then-contents query, shared by CLI and app |
| `Core/TerminalPairing.swift` | the link, its validation, and the Ghostty protocol + mock |
| `Core/PairingStore.swift` | the 0600 link file |
| `App/GhosttyAdapter.swift` | four read/focus operations, and nothing else |
| `App/PairingWindow.swift` | read → check → confirm |
| `Core/SessionContext.swift` | on-demand transcript excerpts, bounded and attributed |
| `AAStatus/SessionContextCommand.swift` | the `--session … --context` mode |
| `App/BranchService.swift` | off-main branch reads, rate-limited |
| `App/SessionContextWindow.swift` | the Recent conversation window |

| Changed | |
|---|---|
| `Core/BackgroundEvidence.swift` | cron handling, complete-shape requirement, failure precedence, `CompletionCertainty` |
| `Core/AttentionEngine.swift` | generic-signal gate, withdrawal, ask dominance, migration, TTL sweep |
| `Core/Models.swift` | `AttentionKind.isGeneric`, `completionCertainty`, **`attentionCertainty`**, `SessionNameStyle.readableName`, `backgroundSupersededAt`, scoped `isWaitingOnBackgroundWork`, `.evidenceWithdrawn` |
| `Core/StatusReport.swift` | four-valued `attention`, `sessionsUncertain`, uncertainty warning |
| `Core/SessionRegistry.swift` | session-name cap 80 → 240 |
| `App/BubbleController.swift` | press routing, context menu, testable drag/release, cursor release |
| `App/ClickableViews.swift` | interactive hit-test, scoped cursor invalidation, cursor set from enter/move, **opt-in `CursorDiagnostics`** |
| `Core/TerminalPairing.swift` | `SessionLinkState` — the offline three-state link rule |
| `Core/FinalHandoff.swift` | **new** — reads a final message for a dedicated handoff footer, in memory |
| `Core/BridgeProtocol.swift` | **new** — the wire format, states and bounds |
| `Core/BridgeHost.swift` | **new** — owned sessions, correlation, idempotency, uncertainty |
| `Core/BridgeClaudeLauncher.swift` | **new** — the documented streaming client launch, bounded |
| `Core/BridgeSocket.swift` | **new** — owner-only Unix socket, bounded I/O, safe bind |
| `Sources/AABridge/main.swift` | **new** — `aa-bridge`, host and client |
| `Scripts/bridge-live-check.sh` | **new** — the opt-in disposable live proof |
| `Core/HookTranslator.swift` | `Stop` handoff classification; subagent events become housekeeping |
| `Core/HookIngestion.swift` | a generic override yields to a specific payload reading; housekeeping is not spooled |
| `App/AttentionPanel.swift` | **the single row list**, `Row` ranking, the `⋯` menu, sound + settings header, freshness footer |
| `App/AppDelegate.swift` | `onSettingChange` persistence with a truthful result, mute applied to speech everywhere |
| `App/TerminalActivator.swift` | live liveness re-probe, Ghostty re-pin, frontmost verification, `TerminalAppControlling` seam |
| `App/GhosttyAdapter.swift` | serialized bounded script execution, refuses a late focus, `frontmostApplicationPID()` |
| `App/PairingWindow.swift` | `Bool`-returning persistence callbacks, generation/busy gating, live probe at confirm |
| `App/SessionContextWindow.swift` | **Open session** and its relink offer, generation/in-flight gating, a window background, a synchronous seam |
| `Core/Config.swift` | `soundEnabled`, `speechIsAudible` |
| `Core/ScriptExecution.swift` | **new** — `ScriptExecuting` and the process-wide `BoundedScriptRunner` |
| `Core/TerminalPairing.swift` | `.busy` failure, `MockGhostty.focusedReadCount` |
| `App/UICheck.swift` | menu, routing, drag, cursor-scope and copy checks |
| `Scripts/smoke-test.sh` | discovery fixture compiles its own helper |
| `AAStatus/main.swift`, `README.md`, `BACKLOG.md` | documentation |

---

## 4. Verification

| | Result |
|---|---|
| `./Scripts/test.sh` | **439 tests in 27 suites**, clean |
| `./Scripts/smoke-test.sh` | **170 / 170**, run against the **release** binaries, isolated home |
| `AgentWarden --uicheck` | **281 / 281**, and **289 / 289** with `--png` (the fixture renders) |
| `swift build -c release` | clean |
| Codex's `check-notification-policy.py` | **8 / 8** (was 2 / 8) |
| Codex's `check-config-policy.py` | **3 / 3** (was 0 / 3) |
| Codex's `check-context-policy.py` | **9 / 9** — including the four identity cases added mid-turn |

### Codex's independent repros

Both re-run against the compiled binaries, unmodified scripts, expectations unchanged.

`check-config-policy.py` — was **0 / 3**:

```
off_unknown     pass  0 items  state=unknown
off_background  pass  0 items  state=backgroundWaiting
off_failure     pass  1 item   [error]  state=awaitingUser
```

`check-notification-policy.py` — was **2 / 8**, still 8 / 8 after these changes:

```
unknown_stop               pass  0 items  state=unknown
cron_only                  pass  0 items  state=backgroundWaiting
confirmed_turn             pass  1 item   [workComplete]
background_stop            pass  0 items  state=backgroundWaiting
ask_then_background        pass  1 item   [approval]  state=awaitingUser
unknown_then_idle          pass  0 items  state=unknown
completion_then_background pass  0 items  state=backgroundWaiting
failed_background          pass  1 item   [error]
```

No expectation was weakened in either script.

### Layout fixtures

`AgentWarden --uicheck --png build/qa/panel.png` writes four panel fixtures and one pairing fixture:

| File | What it is for |
|---|---|
| `build/qa/panel.png` | the representative layout — the five worktrees this is used on, each with its own branch, one row per state worth seeing |
| `build/qa/panel-long-names.png` | a name long enough to wrap, plus mixed states and a snooze |
| `build/qa/panel-crowded.png` | fourteen sessions, the cap and the expand control |
| `build/qa/panel-errors.png` | a failure and an uncertain turn |
| `build/qa/pairing.png` | the linking window after a read |
| `build/qa/context.png` | the conversation window, showing **Open session** beside Refresh and Close |

All five are **fixtures**: constructed records, no live sessions, nothing read from disk, and the
status line is cleared before each render so no earlier check leaks into the picture. It renders this app's
own view into a bitmap: it does not capture the screen, needs no OS grant, and cannot see any other
application. The fixture shows the single list: requests above the line, quiet sessions below,
a paused session stating its own evidence, an uncertain one saying so, the header's speaker and
gear, and the freshness / version footer. It is a **fixture**, not a screenshot of live sessions.

### Discovery, against the real registry

Read-only, isolated `AGENT_ATTENTION_HOME`: six sessions considered, six verified, none rejected,
all `process=alive`, all `attention=awaitingFirstHook`, nothing pending.

---

## 5. Verified in code vs verified by running

Stated plainly, because the difference matters for what Codex still needs to test.

| | Status |
|---|---|
| Notification policy end to end through the real emitter, spool and engine | **run** — Codex's script and the smoke suite |
| Parser: crons, malformed shapes, failure precedence, mixed statuses | **run** — unit tests |
| Withdrawal, ask dominance, snooze survival, migration | **run** — unit tests |
| `aa-status` certainty and `--waiting` trust, with a live app snapshot | **run** — unit tests |
| Long session name from registry file → identity → engine | **run** — unit test over a real fixture record |
| Bubble menu **contents**, and that Quit's action fires | **run** — `--uicheck` against a stub target |
| Bubble press **routing**: right-click and control-click open the menu, do not toggle, do not drag | **run** — `--uicheck` through the real routing, drag-slop and release code |
| Cursor policy: interactive hit-test, scoped release on disable/hide/unclickable | **run** — `--uicheck` |
| A disabled control inside a card keeps its own hit and does not activate the card | **run** — `--uicheck` over a real view tree |
| Branch read from all five real worktrees, matching independent verification | **run** — `--selftest` against the real registry, read-only |
| `notARepository` and `denied` reported as themselves, never as a branch | **run** — smoke, against directories created for it |
| The repository is unchanged after a read (branch and working tree) | **run** — smoke |
| Naming: generated labels lose, chosen names win, worktree is the fallback | **run** — unit tests |
| Context: foreign session skipped, symlink escape refused, thinking/tools excluded | **run** — unit tests and smoke |
| Context bounds: message count, excerpt length, tail, growing file, malformed lines | **run** — unit tests |
| A question with no corroboration reads `unknown`, never `unanswered` | **run** — unit tests and `--uicheck` |
| Reading a transcript changes no queue and writes nothing | **run** — unit tests and smoke |
| `--context` exit codes 0 / 2 / 3 | **run** — smoke |
| The outside-click rule: closed / open / menu-open / just-after-menu / later | **run** — `--uicheck`, pure function with an injected clock |
| The global monitor installs and removes cleanly, with no permission grant in this process | **run** — `--uicheck` |
| Closing and reopening the panel leaves every card, snooze and count untouched | **run** — `--uicheck` |
| Snooze and Dismiss act on exactly one card and leave the others whole | **run** — unit tests and `--uicheck` |
| The row's `⋯` menu carries the shared cursor handling, and a disabled one gives the arrow back | **run** — `--uicheck` over the rendered row |
| One row per full session id: a session with an open request is not also drawn as a card | **run** — `--uicheck` over the rendered tree |
| Snooze and dismiss exist only on rows that have a notification | **run** — `--uicheck` |
| Sound is a master switch: muted silences speech, remembers it, and unmuting replays nothing | **run** — unit tests and `--uicheck` |
| A setting that fails to save is reported, and the control keeps showing what is stored | **run** — `--uicheck` with a refusing persistence callback |
| Muting changes nothing about what raises attention | **run** — unit test through the engine |
| The panel and `aa-status` agree on whether a session needs you | **run** — unit test comparing the report against the shared rule |
| A link whose Claude process has since died, or whose Ghostty is not frontmost, is not called success | **run** — `--uicheck` with mocked Ghostty and an inert app controller |
| A pairing write that fails never shows as "Linked" | **run** — `--uicheck` |
| A child that prints and exits at once still hands back its output | **run** — unit test, twelve repeats, real child processes |
| **Two adapters, one gate**: a second request is refused while a first is blocked, and is never sent afterwards | **run** — unit tests on the runner *and* `--uicheck` across two real `GhosttyAdapter` instances with an injected executor |
| A request whose deadline passed before it could start is dropped unsent | **run** — unit test |
| A runner released mid-script still frees the gate | **run** — unit test |
| Every script carries the Apple event's own timeout | **run** — `--uicheck` asserts the sent source |
| A failed focus raises nothing, and a raise that leaves another app in front is not "exact" | **run** — `--uicheck`, including `activate` returning true with the wrong frontmost pid |
| A session replaced under the same id during the read cannot be linked | **run** — `--uicheck` |
| A Ghostty that restarts during the read cannot be confirmed from | **run** — `--uicheck` |
| The title-bar close drops a confirm in flight (with an open-window control case) | **run** — `--uicheck` through `windowWillClose` |
| A session past the list cap is reachable, and its row and menu act on it | **run** — `--uicheck` |
| A row that needs you shows its branch; a finished turn is styled calmly | **run** — `--uicheck` |
| No self-check asked to activate, script or drive a real terminal | **run** — `--uicheck` asserts the safety brake never fired |
| A row disabled between press and release does not still activate | **run** — `--uicheck` |
| Notification toggles suppress the alert only — state, evidence and failures survive | **run** — Codex's `check-config-policy.py` and unit tests |
| A replayed stall cannot displace working, ask or paused state | **run** — unit tests |
| Confirmed evidence cannot be reused after work resumes | **run** — unit tests |
| **Quit actually terminating the app, and not respawning** | **code only.** `NSApp.terminate` is wired through one constructor; terminating inside a check would end the check. Codex to verify on the installed build |
| **The menu appearing under a real right-click** (`NSMenu.popUpContextMenu`) | **code only** — needs a window server and a real event |
| **The pointer's actual shape on screen** | **code only, and this is where the bug lived.** The checks now drive `mouseEntered` and `mouseMoved` from `NSCursor.iBeam` and assert what `set` was called with — the messages AppKit really delivers to a non-key window — instead of `cursorUpdate`, which it does not. A real pointer over a real bubble is still not simulated, so **only live observation can confirm the fix**; the user's report was against the installed 0.10.2 and has not yet been re-observed |
| A row's `⋯` and the bubble take the cursor back on entry and on movement | **run** — `--uicheck`, eleven checks that failed before the change |
| **A real click in another application collapsing the panel** | **code only** — the rule and the monitor are exercised; a live cross-application click is not |
| Panel appearance: blur, dark mode, Retina | **render only** — `build/qa/panel.png`, not a screenshot |
| iTerm2 / Apple Terminal / tmux / Ghostty activation | **not verified** — no real script call was made, by instruction. The *decisions* are exercised against `MockGhostty` and `InertTerminalApps`; a mock proves the decision, never the live behaviour |
| **Bringing a real application forward** | **no longer possible from a check.** Before the `TerminalAppControlling` seam existed, `--uicheck` called `NSRunningApplication.activate()` on the machine's real Ghostty; that path is now inert in checks. Reported rather than quietly fixed |
| Hooks firing from a live Claude Code session | **not verified** — payloads are transcribed from real captures |

Nothing was installed. The live build, `settings.json`, the hooks, the login item and the real
`AGENT_ATTENTION_HOME` were not touched; every run used an isolated data home and a fixture Claude
home.

---

## 6. What I would like checked

1. **`BackgroundEvidence.read`** — whether any payload shape can still reach `.none` without both
   arrays being present and empty, and whether `types` could carry content (capped at 32 characters
   per entry; the cap is the only thing stopping it).
2. **The generic-signal gate in `applyAttention`** — specifically the fall-through when an ask is
   already open. It is what makes "one wait, one card" still work; it is also the one path where a
   generic signal is not fully passive.
3. **The migration** — a real 0.4 or 0.5 `state.json` restored under 0.6. The rule is "a real ask
   survives, an unsupported claim does not"; worth checking against an actual saved file rather than
   a constructed snapshot.
4. **Quit on the installed build** — that it terminates, that the login item does not respawn it,
   and that hooks, settings and the login preference are untouched afterwards.
5. **`ClickableView.isInteractive`** — whether any control in the panel is misclassified in either
   direction.
6. **`--waiting` answering 2 more often than before.** This is intended, but it changes what a
   script sees; worth a second opinion on whether the threshold is right.
7. **The row's primary action, on the installed build.** The routing is asserted against the
   rendered tree, but "a linked row lands on the right tab and Ghostty is genuinely in front" needs a
   real Ghostty, which I did not touch. `AttentionPanelController.primaryAction` is the one place to
   check that no path guesses a tab.
8. **The `⋯` menu under a real click.** `NSMenu.popUp` needs a window server and a real event; the
   checks build the menu through the same code and fire its items through target/action.
9. **Mute on the installed build** — that muting silences the system sound *and* speech, that
   unmuting says nothing about what happened while muted, and that `config.json` keeps every
   hand-edited field across the change. No audio was played on this machine, by instruction.
10. **`TerminalAppControlling`** — whether any remaining path can raise or launch an application
    from a check or a test. That was a real defect found in an earlier pass, and I would rather it
    were looked for again than assumed gone. `ActivationSafety` is now the backstop, and the check
    asserts it never fired.
11. **The scripting gate under a real hang** — `BoundedScriptRunner` is proven against an injected
    executor. What a genuinely wedged Ghostty does to `NSAppleScript` (whether `with timeout of`
    reliably returns -1712, and how long the process holds the gate afterwards) can only be seen on
    a live machine, and I did not touch one.
12. **`.busy` as a user-facing outcome.** Refusing rather than queueing is the right trade, but it
    means a click during a slow Automation call does nothing except say so. Worth a view on whether
    that message reads as "try again" rather than as a fault.
13. **The confirm-time identity check** — `currentIdentity` compares pid and start time against the
    engine's live record. Whether that is the right authority (versus a fresh registry read) is a
    judgement call worth a second opinion.

---

## 7. Scope

- **Exact session targeting in Ghostty remains UNMET.** Unchanged this pass; no Ghostty control was
  attempted. The button still says "Open Ghostty" and an app-only jump still leaves the item pending.
- Phase two (background shells, monitors, processes), sounds, work-arc phases and event subscription
  are **roadmap only** and unimplemented. Reading the `Stop` hook's task *counts* is not phase two:
  no inventory, no pid, no port, no way to end anything.
- All monitoring and decisions are local. No network calls, no model calls, no telemetry.
- No transcript ingestion. Message text is opt-in and capped.
- No commits, pushes, branches or publication. Nothing installed; no login item created.
