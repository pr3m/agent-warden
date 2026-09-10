# Agent Warden

A macOS app that watches several Claude Code sessions at once and tells you which one needs you —
and why. A small floating bubble is always on screen; click it for the queue. Silent while the
agents are working.

> **Prototype.** Local install only. The app is ad-hoc signed and **not** notarised, so it is built
> from source rather than downloaded. Ad-hoc signing is what gives it a stable identity for the
> Automation permission across relaunches; it is not a Developer ID, and there is no Team ID.
> Notarisation and distribution are out of scope — see [Status and roadmap](#status-and-roadmap).

> The display name is provisional. The Swift modules and the local data directory keep the original
> `agent-attention` / `AgentAttention` spelling. This project is unrelated to any other tool called
> "warden".

## What it does

- **A bubble, always there.** A compact graphite circle near the bottom-right corner, with a badge
  when something is waiting. It stays put at zero pending — a glance tells you the sessions are
  being watched, not just that something has gone wrong.
- **Click to expand.** The bubble opens a panel anchored to it: **one row per session**, in one
  list, sorted so whatever is asking for you is at the top. The session's *name* gets the width and
  wraps to a second line; under it, either the open request or what that session is actually doing.
  The row itself is the action. Everything else — the conversation, linking, snooze, dismiss, and
  all the technical detail — is behind one always-present **⋯** menu in the same place on every row.
  Click the bubble again to collapse.
- **Named by the worktree, not by an identifier.** Six sessions in one repository were labelled
  `acme-36`, `acme-0c`, `acme-6e`, `acme-e9` — client-generated names, two characters apart. The
  row shows the worktree instead, which is what you call it and what its branch is named after. The
  generated label is kept in full, in **Details**. A name a person actually chose still wins.
- **The branch it is on now**, read from the working directory. Not the one stamped when the session
  started — five live sessions all reported `main` while they were each on their own `feat/…` branch.
- **Recent conversation, on request.** Ask a session what it is working on and get back what was
  actually said, attributed and timestamped. Never a summary, never automatic, never persisted.
  **Open session** in that window goes to the linked Ghostty tab — resolving the session again at
  the click, dismissing nothing, and offering to link a tab when there is none.
- **Link a session to its terminal tab.** Ghostty cannot tell anyone which tab a session is in, so
  you say so once — and then *Open linked tab* focuses that exact tab, checks it landed, and refuses
  rather than guessing when the link no longer holds.
- **A turn that hands something back is a request, not news.** When a session ends its turn with a
  dedicated `I need from you:` line, that shows as **Waiting for you** — even if it also left a shell
  running, because "a decision is needed" and "work is still going" are both true. A footer that says
  `nothing` stays silent, as do questions in prose, quoted examples and code samples. The message is
  read in memory and never stored; the card carries a fixed reason unless you switch message text on.
  Deliberately *not* supported: finding requests in ordinary prose, and recovering ones that were
  missed before this existed. Both would need their own design.
- **Roam — work with the lid shut.** One menu item keeps the Mac awake while you carry it, holds an
  idle-sleep assertion, watches the battery, and puts the machine to sleep deliberately before the
  charge runs out rather than letting it die mid-session. See [Roam](#roam).
- **One queue, all sessions**, sorted by how much each is blocking you.
- **One wait, one card.** Claude Code describes the same wait more than once — a permission
  request, then its own permission prompt, then an idle prompt a minute later. Those collapse into
  a single card whose count goes up and whose description gets *sharper*, never vaguer.
- **Never steals focus.** Both the bubble and the panel are non-activating windows. A new alert
  expands the panel; it cannot interrupt what you are typing.
- **Dismiss and snooze that stick.** A dismissal holds for the rest of that wait, however many more
  times Claude Code describes it. Both survive follow-up signals and an app restart.
- **Silence is never evidence.** Every alert comes from an official Claude Code hook. Elapsed time
  produces nothing at all — no card, no badge, no sound — however long a session has been quiet.
  A legitimate task runs for hours; a monitor that cries "stalled" at it is worse than no monitor.
- **Paused is not finished, and unknown is neither.** When a turn ends, the `Stop` hook's own task
  and cron lists say what it left behind. Something still running or scheduled → *waiting on
  background work*, counted apart from the queue because nothing is being asked of you. Both lists
  present and empty → *turn complete*, and only then. Anything else — a missing list, a status we
  do not recognise, an older Claude Code — is **uncertain**, and uncertainty is silent: no card, no
  badge, no sound. A failed background task is the exception, and is raised as an error.
- **Only a real request rings.** Questions, approvals, stage decisions and errors are always
  actionable. "The turn ended" and "waiting at the prompt" are *states*, not requests, and become a
  card only when structured evidence confirms the turn finished.
- **Ask without looking.** `aa-status --json` answers "who needs me?" for a script or an assistant,
  read-only, and says plainly how much the answer can be trusted.
- **What is running behind a session, job by job.** A turn that hands off to a shell, a subagent or
  a monitor is not a turn that finished. Each job is tracked by session **and** task id, with its
  own kind, state (running, completed, failed, **stopped**, unknown), source and freshness — shown
  as one compact line beside the request, with per-job detail on demand. The list never claims to be
  the whole list: an empty registry means *we have not heard*, never *there is nothing running*.
- **One working agreement, wherever you keep it.** Point Agent Warden at a Markdown or text
  document and any local consumer can ask what the current agreement is — read fresh, with a
  digest so a change is detectable. Optional, unset until you choose one, never written, never run.
- **An optional signature chime** — two short notes, generated in-process, for a genuine ask only.
  Off by default, including on an update: nothing starts making noise because you upgraded.
- **Optional local speech**, off by default, on-device only.

Everything above happens locally, in a Swift process on your machine: no network calls, no model
calls, no polling of any assistant, no telemetry. It never answers anything for you — no
orchestration, no auto-approval, no writing into a session. The phase-one assistant interface is
**read-only**.

## The bubble

| | |
|---|---|
| **Default position** | Bottom right, lifted ~120pt clear of the corner |
| **Move it** | Drag it anywhere, or use the menu bar item → *Bubble position* (four corners, nudge, reset) |
| **Memory** | The position is stored as a corner plus an inward offset, so it survives a resolution change, a different display and a relaunch |
| **Safety** | Always clamped fully inside the usable screen area — a remembered position from a 5K display still lands on a laptop panel |
| **Empty state** | Bubble stays, badge disappears, panel says "No confirmed requests" — never "nothing needs you", which it cannot know — and still lists session status |
| **Right-click it** | Opens the bubble's own menu: what is waiting, show/hide sessions, bubble position, reveal the data folder, and **Quit Agent Warden**. Control-click does the same |
| **Click away** | The panel closes. The bubble stays. Nothing in the queue changes |
| **Turn it off** | Menu bar → *Floating bubble*. The menu bar item is the secondary surface and remains either way |

**Coexisting with other floating controls.** The default deliberately sits above the very corner,
because assistant controls (ChatGPT's voice control, for example) tend to live there. We do **not**
try to detect them: that would need window-list access this app does not ask for, and a promise it
could not keep across every app and space. Dragging and the corner/nudge menu are the answer, and
the expanded panel is anchored to wherever you put the bubble, so it moves out of the way too.

**Three questions, three answers.** What the turn is doing, what it is *asking* for, and what is
running behind it are tracked separately and shown separately. "Needs your approval · 1 monitor
running" is two facts, and collapsing them loses one: a monitor that runs all day must never silence
a question, and a shell finishing must never read as a goal being met. A queued alert is rechecked
against the session's current episode before it sounds — a generic "the turn finished" is cancelled
once the session carries on, while a genuine ask is not cancelled by unrelated background progress.

Per-job detail is identifiers and vocabulary only: a task id, its type, its status, whether a
scheduled wakeup recurs. Commands, prompts and descriptions are never read. Actual emission of the
live task stream by the installed client is **not yet verified** — until it is, stream coverage
reads `unknown`, and `local_bash` alone cannot tell a one-shot shell from a monitor.

**Readable because of itself, not because of what is behind it.** The panel used to be a
translucent HUD material, so how legible the text was depended on the page underneath — over a white
browser window the surface lightened and the supporting text washed out. It is now an **opaque
graphite plate**: the window stays transparent only so the corners can be round and the shadow can
fall outside them. The bubble is opaque for the same reason. Both windows pin their appearance to
dark, so a system switch to Light cannot resolve a semantic colour into near-black on a dark plate,
and every colour drawn on the plate is stated in sRGB rather than inherited.

`AgentAttention --uicheck --readability <dir>` measures it: each surface is composited over white,
over near-black and over a busy pattern, the interior pixels must come out identical (that is the
opacity proof), and the contrast of every colour against the plate **as rendered** must clear
4.5 : 1 for text and 3 : 1 for controls. It writes the composites to that directory. Those are
*fixture* images — this app's own views over backdrops it made — not a capture of the panel over a
real window.

**The pointer tells the truth.** Anything clickable shows a pointing hand while you are over it;
anything disabled does not. Borderless non-activating windows get no cursor management for free —
walk off a terminal onto the bubble and you would otherwise still be holding an I-beam — so the
cursor is set from a single policy, and only ever `set`, never pushed onto a stack. There is
no cursor stack to unbalance. Live cross-application hover behavior still needs user verification.

**Clicking away closes the panel.** Click anywhere that is not Agent Warden and the expanded panel
folds back to the bubble — the same as pressing *Collapse*. This is **presentation only**: nothing is
dismissed, snoozed or resolved, the badge count is unchanged, every snooze still stands, and one
click on the bubble brings the panel straight back with the same cards.

How it watches matters as much as what it does:

- it uses a **global mouse monitor**, which by design observes only events that were delivered to
  *another* application and cannot consume them. Whatever you actually clicked receives its click in
  full — nothing is intercepted;
- it needs **no Accessibility permission**. That requirement applies to keyboard monitoring; mouse
  monitoring is ordinary API, and the app asks for no new grant;
- clicks inside our own windows never reach a global monitor at all, so the panel, the bubble, their
  buttons and the drag handling need no special case;
- while one of our own menus is open — **Details** on a card, or the bubble's context menu — outside
  clicks are ignored, so asking for a menu never closes the panel out from under it.

**Right-click, or control-click.** The bubble carries its own menu — the badge count, show/hide
sessions, bubble position, reveal the data folder, and **Quit Agent Warden**. Opening it never also
toggles the panel and never starts a drag; a plain click and a drag behave exactly as before. Quit is
built by the same constructor the menu bar item uses, so there is one termination path, not two: it
saves the queue, clears the presence file, and touches nothing else — not your hooks, not
`settings.json`, not the login item. The login item is `RunAtLoad` with `KeepAlive` off, so quitting
does not respawn the app; it returns at your next login.

Accessibility: the bubble is an accessibility button with a spoken label that includes the count
("Agent Warden. 3 sessions waiting."), a help string, and a press action. Every card, button and
session row in the panel carries a label. Because the windows are non-activating by design, they do
not take keyboard focus — the menu bar item carries the same actions for keyboard-only use.

## What raises an alert

| Reason | Source | Comes from |
|---|---|---|
| Asked you a question | reported | `PreToolUse/AskUserQuestion`, `Notification/agent_needs_input`, MCP elicitation |
| Stage decision | reported | `PreToolUse/ExitPlanMode` (a plan is ready to approve) |
| Needs approval | reported | `PermissionRequest`, `Notification/permission_prompt` |
| Turn failed | reported | `StopFailure`, quota auto-resume problems |
| Work complete | reported, **and confirmed** | `Stop` with both task lists present and empty |
| Background task failed | reported | `Stop` with a task in a failed state |

And two things that are **not** on the list, because they are states rather than requests:
`Notification/agent_completed` and `Notification/idle_prompt`. They carry no structured evidence, so
on their own they change a session's *state* and nothing else. If a wait is already open they count
as another sighting of it; they never open one.

Every row says *reported*, and that is the whole list. **Nothing is inferred from elapsed silence.**
Earlier builds raised a "suspected stall" after five minutes of quiet; that has been removed
outright, not lengthened. A session that has been silent for six hours is treated exactly like one
that has been silent for six seconds, because a long-running task looks identical to a stuck one
from the outside and only the person watching it can tell the difference.

That order is also the order used to sharpen a card. Leaving plan mode fires
`PreToolUse/ExitPlanMode` and then, seconds later, a generic `permission_prompt` — the card keeps
saying "plan ready to approve" rather than degrading to "permission needed".

Ordinary work (`UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `SubagentStop`,
`SessionStart`) is a heartbeat and never raises anything.

The installed hook entries pass the classification to the emitter as an argument
(`aa-emit --kind approval`), chosen by Claude Code's own matcher. Payload fields are only a
fallback, so a field rename upstream cannot silently make the app deaf.

## Sessions that were already running

Hooks only tell us about a session once it does something. A session sitting at a prompt since
before Agent Warden started would be invisible — which is exactly when you most want to know it is
there. So the app also reads Claude Code's own session registry (`~/.claude/sessions/*.json`),
read-only, and lists what it finds.

Those sessions are labelled **"awaiting first hook · attention unknown"**, and that label is the
whole point:

- they are **not** counted as working;
- they **never** produce an attention item, a question or an approval;
- registry `status: busy` is shown verbatim and never interpreted — it goes stale by design and can
  be a quarter of an hour old;
- the moment a real hook arrives for that session id, it merges into the same row: hook coverage
  flips to known, and the hook's working directory wins over the registry's launch directory.

Verification before anything is listed: the pid must be alive, must be running a Claude executable,
and must have been born when the record says. A dead pid, a recycled one or a mismatched executable
is rejected. Where process inspection is refused, nothing is claimed at all.

| Boundary | |
|---|---|
| Files read | `~/.claude/sessions/*.json` only |
| Never read | the sibling `*.key` peer-token files |
| Never used | `messagingSocketPath` — no socket is opened, ever |
| Writes | none; discovery is entirely read-only |
| Transcripts | a bounded 64 KB tail, from which only `cwd`, `gitBranch` and `sessionId` are taken. Message bodies are never read, kept or logged |
| Stability | this is Claude Code's internal bookkeeping, not a published API. Absent, malformed, oversized or newer-schema records are skipped, and the feature degrades to hooks-only |

Set `AGENT_WARDEN_CLAUDE_HOME` to point discovery somewhere else; the tests and smoke suite use it
so they can never list the real sessions on the machine running them.

## Waiting on background work

A turn can end while work carries on behind it — a background shell, a subagent, a scheduled job.
Announcing "work complete" there is simply wrong, and it happened in testing: a session started a
background Bash task at 08:27:55Z, ended its turn 44 seconds later, and the app said it was done.

Claude Code's `Stop` hook carries `background_tasks` and `session_crons`, so no guessing and no
reading of transcript text is needed. What the app does with them:

**Both arrays are required.** `session_crons` are scheduled wakeups — pending work just as much as
a running shell. An empty task list beside a scheduled cron is not a finished turn, and a *missing*
cron list means we did not get a complete answer, so it cannot be a finished turn either.

| The payload says | The app says | In the queue? |
|---|---|---|
| both lists present, something running or scheduled | *Paused — 1 background shell still running* | no — nothing is being asked of you |
| both lists present, both empty | *Turn complete* | yes, as a normal completion |
| a task in a failed state | *1 background task failed — 2 still running* | yes, **as an error**, even while other tasks run |
| a status we do not recognise | *Turn ended — completion not confirmed* | **no.** Uncertainty is passive |
| either list missing or malformed | *Turn ended — completion not confirmed* | **no.** Uncertainty is passive |

That last pair is the important one. An unreadable payload is not a milestone, so it does not get a
card, a badge or a spoken alert — it changes the row's state to "turn ended · state not confirmed"
and stops there.

**Evidence is spent once work resumes.** A confirmed `Stop` describes the turn it ended. If the
session goes back to work and a later `agent_completed` arrives carrying nothing of its own, it
cannot reuse that older reading to claim a fresh completion. The reading stays on the record as a
description of what the session left running; it simply stops confirming anything. A new `Stop`
confirms again on its own evidence. And if a completion card is already on screen when a later `Stop` says work is
still running, the card is **withdrawn**: it was a claim the evidence no longer supports. A real
question, approval or error is never withdrawn this way, and keeps its snooze.

Three rules hold throughout:

- **Only counts are kept.** The entries carry `description`, `command` and `prompt`; none of that
  is read, stored or displayed. What is persisted is running / completed / failed counts, the task
  *types* (`shell`, `subagent`, …) and a timestamp.
- **Unknown is its own answer.** An older Claude Code that does not emit the arrays, a malformed
  entry, or a status outside the vocabulary makes the reading *uncertain* — which resembles neither
  "busy" nor "finished".
- **A stale reading is not a claim about now.** After 30 minutes (`backgroundEvidenceTTLSeconds`)
  the pause expires, the session goes to *uncertain* rather than staying paused — and, because
  uncertain is not confirmed, an idle prompt arriving afterwards still cannot turn it into an alert.
- **The pause is about the session, not the snapshot.** Once a session does real work again it is
  *working*, even though nothing ever tells us the task finished. The reading is kept as-is; it is
  never rewritten into a completion to make a count tidy.

An explicit ask always wins: a permission prompt, a question or an error during background work is
raised immediately. Being busy is not a reason to sit on a request for approval.

## What a session is called, and what branch it is on

**The name.** Claude Code's registry gives a session a `name` and a `nameSource`. Only a name whose
source says a person chose it (`user`, `custom`, `explicit`, `manual`, `set`, `named`) is used as the
label. Everything else — `derived`, `auto`, or no source at all — is a client-generated identifier,
and identifiers make poor names: `acme-36`, `acme-0c`, `acme-6e` and `acme-e9` were four sessions
in one repository. The row shows the **worktree** instead. The generated label is preserved verbatim
in **Details**, alongside its source, so nothing is lost.

Nothing is invented. No name is derived from a transcript, from message content, or from a model.

**The branch.** The transcript records `gitBranch` when a session starts and never revisits it, so a
session that moved into a worktree afterwards still claims the branch it launched on. In practice
that meant five live sessions all reporting `main`. Agent Warden now reads the working directory
itself:

```
git -C <cwd> --no-optional-locks branch --show-current
```

| Rule | Why |
|---|---|
| `branch --show-current` and nothing else | It reads `HEAD`. No fetch, no index write, no remote, no network. |
| `--no-optional-locks`, `GIT_OPTIONAL_LOCKS=0` | It cannot take the index lock, so it cannot interfere with a `git` command you are running in that same worktree. |
| `GIT_TERMINAL_PROMPT=0`, no stdin | It can never sit waiting for input. |
| A 2-second timeout, then the process is killed | A repository on a stalled mount answers `timedOut` rather than hanging the app. The deadline starts *before* the child does, and both pipes are drained concurrently — reading one to the end and then the other deadlocks against a chatty child and never returns at all against a hung one, which would make the timeout a decoration. Output is bounded, and the excess is read and discarded rather than left to block the child. |
| Off the main thread, one at a time, re-read at most once a minute | The UI never waits for `git`. |
| Arguments passed as an argument vector | A path with spaces, quotes or `$` in it is just a path. There is no shell. |

Every outcome is shown as itself. `detached HEAD`, `not a git repository`,
`branch unreadable (permission)` and `branch unreadable (git did not answer)` are all real answers,
and none of them is ever rounded up to a branch name. A reading taken from the directory overrides
the transcript's, including for sessions that hooks already cover — hook coverage does not make a
value that was never read from the directory correct. It never overwrites the hook's working
directory or anything about attention.

## Linking a session to its Ghostty tab

Ghostty 1.3.1 tells you a terminal's **id**, **name** and **working directory** — and not its pid or
tty. So nothing in the running system can prove which tab a Claude session is in. Matching on
directory or title would be a guess, and a guess sends you to somebody else's tab with full
confidence. The person who knows is you, so you say it once, per session:

**Details → Link Ghostty tab…**

1. In Ghostty, click the tab that session is running in. Agent Warden does not open, close, switch
   or restart anything for you.
2. In the pairing window, press **Read selected tab**. It asks Ghostty what is focused and shows it
   back: the terminal id, its name and directory, the tab and window it belongs to, and Ghostty's
   pid — beside the session it would be linked to, with that session's branch, tty and full id.
3. Check it is the right one and press **Confirm link**.

Confirming **re-reads before it saves**. If the selected tab, the Ghostty process or the session has
changed in between, nothing is written and the preview is replaced — a silent switch there would
link the wrong tab. macOS may ask once for permission to control Ghostty; you grant it, and Agent
Warden never grants itself anything.

**What a link is, and what it is worth.** It records the full session id with the Claude pid *and*
its start time, optionally the tty, plus Ghostty's pid and start time and the terminal id. Both ends
are pinned to a process incarnation, so:

| What changed | What happens |
|---|---|
| Ghostty was restarted | The link is refused. A terminal id means nothing across runs. |
| The linked tab was closed | Refused. There is no fallback to another tab. |
| The session's Claude process is not the one that was linked | Refused. |
| Ghostty is not running | Refused. It is never started. |
| Permission was refused, or Ghostty did not answer | Refused. Not being able to check is not permission to guess. |

In every case the item **stays pending**, and the message tells you to link the tab again.

**Navigating.** A linked session's button says **Open linked tab** rather than "Open Ghostty". A
click validates the link, focuses that exact terminal by its own id, and then **reads back what is
focused** — landing on a different terminal, or not being able to confirm, is not reported as
success and does not clear the card. Unlinked Ghostty sessions are unchanged: "Open Ghostty", and
the item stays pending, exactly as before.

**What it can do to Ghostty.** Four things: which Ghostty is running, what is selected, does this id
exist, focus this id. Ghostty's dictionary also offers `input text`, `send key`, `new tab`, `close`
and `quit`; none is reachable from anywhere in this app. Agent Warden looks and points. It never
types into a session.

Links live in `pairings.json` beside the queue — mode `0600`, its own schema, identifiers and
timestamps only. No transcript text, no tokens, no socket paths. `provenance` reads `userConfirmed`,
because that is exactly what the evidence is. When a session ends, its link is retired; nothing
about that touches the attention queue. `aa-status --json` reports the link and a `verdict` checked
at the moment of asking, so nothing has to infer exact navigation from an app merely coming forward.

**Automatic mapping is still unmet**, and this is not a workaround for it — it is a different thing:
a fact you supplied rather than one the system could prove. The upstream capability that would make
it automatic is expected in Ghostty 1.4+ (PR 11922).

## Asking what a session is working on

The queue tells you a session needs you. It does not tell you what it is doing. That is a separate
question, with a separate answer, asked deliberately:

```bash
aa-status --session <full-session-id> --context          # for a human
aa-status --session <full-session-id> --context --json   # for a script or an assistant
```

and, in the app, **Details → Recent conversation…** on any card or session row.

What comes back is what was actually said — recent user and assistant text, attributed and
timestamped. It is not a summary and nothing about it is generated.

| Rule | |
|---|---|
| **Identity before contents** | A transcript is opened only for a session Agent Warden is already tracking. An id it does not know gets nothing read at all — whatever file happens to carry that name — and exits 5. |
| **On demand only** | Nothing reads content on a timer, on a hook, or during monitoring. It is never cached, never written to `state.json`, never logged. |
| **Only the session you named** | Located by **full** session id, and every record required to *carry* that same id. No id at all is not "implicitly ours", and a longer id that merely starts the same is a different session. |
| **Never the wrong file** | Symlinks are resolved and must stay under `~/.claude/projects`; only regular files are read. |
| **Not everything in the transcript** | Thinking blocks, tool inputs, tool result payloads, attachments and subagent sidechains are all dropped. That is where pasted secrets and large blobs live. |
| **Bounded** | A 1 MiB tail, at most 20 messages, 600 characters each, 12 000 in total. Transcripts run to tens of megabytes and are being appended to while we read. |
| **Not evidence** | An excerpt never raises an attention item and never clears one. The queue is built from hooks and only from hooks. |

**The two are reported side by side and never blurred.** The attention state comes from hooks, is
labelled authoritative, and stays visible even when the transcript cannot be read at all. The
conversation is labelled context.

**And "known" means known.** `attention.known` is true only when the state is one we positively know
*and* the queue can be trusted — app running, state fresh, state readable. A saved request from an
app that is no longer running is still reported, because it is a real record, but it is labelled a
record rather than presented as live certainty. Four things are reported separately because they are
four different questions: whether the process is alive (`identity`), how old the queue is, how many
hook events are still unprocessed, and how old the newest message is. The command line and the app
go through the same query, so neither can be more optimistic than the other.

**What a person typed.** A `user` record is not automatically a request: Claude Code writes tool
results, injected notices and compaction summaries with the same role. Only an external prompt with
no tool payload counts as "the latest thing you asked for". Message bodies come in two shapes — a
list of typed blocks and a plain string — and both are read.

**Questions.** Where the transcript contains a structured `AskUserQuestion`, its question and options
are shown as written, and a matching `tool_result` is correlated by `tool_use_id` to say whether it
was answered. A result marked `is_error` — cancelled, refused, interrupted — is **cancelled**, not
answered. And **no result seen is `notObserved`**, never "unanswered", even when the whole file was
read: not seeing an answer is not evidence that one is owed. Only a hook can say a session is
waiting, and that is reported separately and dominates. A question mark in ordinary prose is not a
question.

Exit codes: `0` read · `2` usage error · `3` no transcript for that id · `4` a transcript exists but
could not be read · `5` not a session Agent Warden tracks, so nothing was read · `6` the session **is**
tracked, but its Claude process is gone or could not be pinned to the one on record, so nothing was
read. Six and five are different answers and a script must not fold them together: five means *we do
not know this session*, six means *we know it and it is no longer the one we knew*. Report on stdout,
problems on stderr.

**From the conversation window, Open session** does the same thing a linked row does, with two
differences: the session is resolved from the queue again at the moment you click, so a session that
has ended or been replaced under the same id is refused rather than followed; and it never dismisses
or snoozes anything, because reading a conversation and dealing with a request are different acts.
If there is no link it opens the linking window and says so; if a saved link no longer holds it
explains why and offers to link again, leaving the transcript exactly where it was.

## Clicking a row — what actually happens

There are no per-row buttons. The row is the action, and what that action does depends on what can
honestly be delivered for that session:

| Session | Clicking the row gets you |
|---|---|
| Ghostty, **linked** to a tab | that exact tab, verified after the fact |
| Ghostty, not linked | its recent conversation, with **Link Ghostty tab…** offered there |
| iTerm2 | the exact tab, by its `ITERM_SESSION_ID` |
| Apple Terminal | the exact tab, by its tty |
| tmux + a raisable terminal | the pane, then the terminal window |
| No terminal identified | its recent conversation |
| **Terminal not running** | **nothing — the click is refused, and says so** |

**A linked tab lands, or it fails.** Navigation to a linked Ghostty tab is one transaction: focus
the exact terminal, read back that it landed, and — if Ghostty had to be brought forward — check
again afterwards that the same Ghostty is frontmost, that the same tab is still selected, and that
the session's Claude process is still alive. A failure at any of those points reports the reason and
raises nothing. It never falls back to "Ghostty is in front now", because that leaves you looking at
someone else's tab believing you arrived.

**One scripting request at a time, for the whole app.** While Ghostty is answering, another request
is refused on the spot rather than queued behind it — so a second click cannot fire a tab switch
minutes later. An Apple event already delivered cannot be recalled, and Warden does not pretend
otherwise; what it guarantees is that nothing unsent is sent after its deadline.

The tooltip and the VoiceOver label on every row say which of these it is *before* you click, so a
row never does something other than what it announced.

**Ghostty: exact session targeting is not met, and it is not Ghostty's fault.** Ghostty 1.3
ships a real scripting API — `terminal` has an `id`, and `focus`, `select tab` and
`activate window` all exist (checked against the installed `Ghostty.sdef`, 1.3.1). The missing
half is the link *from a session to its surface*: a running process has no way to learn which
surface it is in. `terminal` exposes only `id`, `name` and `working directory` — no tty, no pid —
and Ghostty exports no surface-id environment variable. Matching on working directory would pick
the wrong tab whenever two sessions share a project, so this app does not guess.

Consequences, deliberately:

- an unlinked Ghostty row opens the **conversation**, never a guessed tab;
- the item **stays pending** — bringing an app forward is not evidence you dealt with anything.
  Only an exact-tab landing clears a card;
- every row has **⋯ → Details**, which shows the project, folder, **full session id**, tty,
  terminal, Claude pid and the link, so you can find the tab yourself;
- clicking never opens a new terminal, and the resume command is only ever copied when you ask.

**A chain beside each session** says whether a Ghostty tab is linked: grey for none, green for one
you confirmed, orange when the saved link names a Claude process this session no longer has. It is
read from disk — no Automation call is made to draw a row — and "saved" never means "verified".
Clicking it opens the same linking window the ⋯ menu uses, and changes nothing else.

**The pointer, honestly.** Rows and controls highlight under the pointer. The *shape* of the cursor
is an open problem: the app's own reading of the cursor is not what the screen shows, so the checks
that passed proved nothing about it. The cause is not yet established and no further change will be
made on a guess. Bounded opt-in diagnostics (`AGENT_WARDEN_CURSOR_DIAGNOSTICS=1`; 400 records, 64 KiB
or ten minutes, written 0600) record what a real hover does. See
[IMPLEMENTATION_REPORT.md](IMPLEMENTATION_REPORT.md) §2e.

**Escape closes what is open** — the conversation window, the linking window, and any menu (macOS
handles those). It closes windows and nothing else: nothing is dismissed, snoozed or resolved, no
session is stopped, and a link you had not confirmed is not saved. It works while you are *in* Agent
Warden; Escape typed into your terminal belongs to the terminal. There is no global key monitor and
no focus is taken to catch a keystroke, and the expanded panel never becomes a key window — click
outside it to collapse it. Tracking uses `.activeAlways`, which suppresses
`cursorUpdate` delivery even in key windows, so the cursor is set from the
events a background window really receives — entering, moving, leaving — and handed back whenever a
target stops being one. No polling, no timers, no permissions, and no focus is taken. These event
paths are tested; actual desktop hover behavior still awaits user confirmation.

**Clicking never starts an application.** It activates an instance that is already running, and
nothing else. If the terminal is not running the session cannot be in it, so the click refuses,
copies the identifying details, and leaves the item pending — a new empty window would not be the
session you were trying to reach.

**Show all N sessions** expands the capped list inside the panel. It never mass-opens tabs.

This is a limitation of the current mapping, not a platform impossibility. If Ghostty exports a
per-surface identifier (discussed upstream; the versioned 1.3.1 source has an internal surface
UUID but does not export it), the fix is one `ActivationStep` and this table changes.

## The orchestration contract

One document, wherever you keep it, holding the working agreement between you and the assistants
you run. Agent Warden stores **a path** and reads that file on request. It has no default location,
assumes no note-taking app, and creates nothing.

**Choosing one.** Settings → *Orchestration contract…*. The window shows what is selected and
whether it can actually be read; you can choose a file with the normal macOS chooser, paste a path,
clear the selection, reveal it in the Finder, or open it for editing. Escape and Close are always
safe, and a change that fails to save says so instead of appearing to have worked.

**Reading it.**

```bash
aa-status --contract --json            # what is selected, and whether it can be read
aa-status --contract --content         # the same, plus the document body
```

Read-only, and independent of everything else: it does not need the app or the bridge to be
running, it re-reads the configuration and the file on **every** invocation, and it holds nothing
between them — there is no cache here to serve a stale agreement out of. It never opens the document
in an application, never runs it, never edits it or your settings, starts no session and grants no
permission.

| Field | What it is for |
|---|---|
| `availability` | `available`, `noSelection`, `missing`, `notRegularFile`, `unsupportedType`, `tooLarge`, `notText`, `unreadable`, `changedWhileReading`, `configUnreadable` |
| `revision` | SHA-256 of the exact bytes — the only reliable way to notice an edit that kept the same size and second |
| `sizeBytes`, `modifiedAt`, `readAt` | when it was read, and what was there |
| `selectedPath` / `resolvedPath` | what you chose, and what that resolves to |
| `content` | only with `--content`, only whole, bounded at 256 KiB |

Exit codes: `0` read · `1` nothing selected · `3` selected but missing · `4` unreadable, changed
mid-read, or the settings could not be read · `5` not a regular file, unsupported type, or not
UTF-8 · `6` too large.

**How a consumer should use it.** Ask for the contract, look at `availability` and `revision`, read
the content when it matters, act **within what you are actually allowed to do**, and ask again when
the work changes or the revision does. That last step is the whole protocol: there is no watcher, no
push, and no automatic reload.

**What selecting a document does not do.** It is not an authorisation and it creates no permission.
It does not make any assistant, voice task or tool load or follow anything — there is no MCP server
here, no automatic loading and no wakeup. Each tool still decides for itself inside its own
boundaries. The contract is *your policy expressed in one place*; project `CLAUDE.md` and `.claude`
harness files remain authoritative for project workflow, Agent Warden handles live sessions and
transport, and Jira and git keep the ticket and code records.

**Safety.** Selecting never runs anything and never changes the file. The reader accepts regular
files only — a directory, socket, device or named pipe is refused without ever blocking on it — and
only plain-text kinds (`.md`, `.markdown`, `.mdown`, `.txt`, `.text`, or no extension). Anything a
machine could execute is refused **by name**: an executable bit, a bundle, or an extension like
`.command`, `.sh`, `.js`, `.html`. *Open for editing* is available only for a document that has
already been read successfully, and hands the file to a **text editor chosen for the plain-text
type** — never to whatever the file's own extension is associated with, so there is no path from
choosing a document to running a program. A file that is temporarily missing stays selected, with a
clear missing state, rather than being quietly forgotten.

## The session bridge — sessions Warden owns

`aa-bridge` is a local interface for driving Claude Code sessions **Agent Warden started itself**.
It is how a voice assistant, or any local caller, can put a session to work and be told honestly
what happened.

```bash
aa-bridge serve --approve <dir> [--no-tools] [--socket <path>]   # the host: owns the socket and its sessions
aa-bridge start --cwd <dir> --request-id <id> [--model opus]     # a NEW session, id generated here
aa-bridge send  --session <uuid> --message-id <id> --prompt …    # one turn at a time
aa-bridge focus --session <uuid>                                 # bring its own tab to the front
aa-bridge status [--session <uuid>]                              # the whole host, or one session
aa-bridge events|stop --session <uuid>
```

- **Owned sessions only.** A session id this host did not create is refused, always. The sessions in
  your terminals are *observed* by Agent Warden and never driven — two things steering one
  conversation, with only one of them visible to you, is not a feature.
- **The states are kept apart.** Written to a pipe, acknowledged *by the client* (its own echo of our
  message, carrying an id we put there), active, a result, completed, failed — or **uncertain**, when
  a client goes or a deadline passes. Nothing is ever resent automatically.
- **One turn at a time per session**, so a result can only ever belong to one request. A second send
  is refused as busy rather than queued into ambiguity.
- **One answer settles one turn.** A result is remembered by its own identity — the `uuid` the
  documented frame carries — so a replayed answer cannot mark a later turn complete. `session_id`
  names the conversation, not the turn, and is never treated as if it did. A *success* additionally
  needs that turn to have been acknowledged: claiming an outcome for a prompt we cannot show the
  client received is exactly the kind of confidence this thing is built to avoid.
- **`stopping` is not `stopped`.** Asking a client to stop and the client having gone are different
  claims, and the phase says which one you have. Only an observed exit turns one into the other.
- **Local only.** A Unix socket at 0600 in your own data directory. No port, no token, no network.
- **Permissions stay Claude Code's.** The client runs with `--permission-prompts none`; nothing here
  answers a permission on your behalf and `--dangerously-skip-permissions` is not reachable.

Live acceptance: `AGENT_WARDEN_LIVE_BRIDGE=1 ./Scripts/bridge-live-check.sh` — one disposable
session in a scratch directory, two harmless prompts, evidence in `build/qa/bridge-live/`.

`aa-bridge` ships inside the app bundle. **The app does not start it**: a host runs only when you
run one, and only with directories you name.

### A session you can watch

By default a bridge session runs in the background, exactly as before. Add `--terminal ghostty` and
it opens in a **new Ghostty tab instead**:

```bash
aa-bridge start --cwd <dir> --request-id <id> --terminal ghostty
aa-bridge focus --session <uuid>      # bring that exact tab forward
```

Claude genuinely runs **in that tab** — Ghostty is asked to create a surface whose command is Agent
Warden's own relay, and the relay runs Claude as its child on that tab's pty. It is not a log viewer
and not `claude attach`, which by its own help opens a session that "keeps running either way"
somewhere else. The tab shows a readable transcript: your prompt, Claude's replies, which tools ran
by name, and how each turn ended. Every character of model output is stripped of control sequences
before it reaches the terminal, so nothing Claude emits can repaint your screen or retitle your
window.

Warden keeps full API control at the same time: `send`, `status` and `events` behave exactly as they
do for a background session, with the same acknowledgement and result correlation.

| | |
|---|---|
| **Typing in that tab** | **Not enabled.** Claude's input is Warden's private pipe, so keystrokes have nowhere to go. The tab says so in its header, and `status` reports `surface.acceptsTyping: false` |
| **Which tab** | A new one in your current window, or a new window when Ghostty has none. An existing tab is never reused, never typed into, and no Ghostty setting is changed |
| **Identity** | The window, tab and terminal ids Ghostty itself returned. No pairing step, no matching by title |
| **Closing it** | Closing the tab ends the session, and `status` says so. `aa-bridge stop` closes only the surface Warden created |

Direct two-way use — you typing in the same session the API drives — is a **future capability**. It
needs a supported transport that can carry both, and an arbitration rule for whose message is whose.
It is not simulated here with keystroke injection, a second Claude process, or an attach mirror.

**What this is not.** It does not enable a channel into a session already open in a terminal, it is
not hosted by the Agent Warden app, and it does not wake a voice conversation. All three are
separate, and none of them is built.

## Install

Requires macOS 14+ and a Swift 6 toolchain (Xcode or the Command Line Tools).

```bash
git clone https://github.com/pr3m/agent-warden.git && cd agent-warden
./Scripts/release.sh        # build → gates → install → restart. One command.
```

`release.sh` is the whole pipeline, so that "it builds" and "it is on your machine and working" stop
being two different facts. It builds the bundle, runs every gate, verifies the bundle can prove what
it is, installs it to **`~/Applications/AgentWarden.app`**, rewires the hooks and the login item at
their new path, links the commands onto your `PATH`, and restarts Agent Warden and nothing else.
Any gate that fails stops it before the running app is touched.

| Step | What has to be true |
|---|---|
| Build | the bundle compiles and is ad-hoc signed |
| Gates | tests, smoke and the UI check all pass |
| Verify | every bundled executable is present, executable, and reports the *same* version; the bundle satisfies its own signature |
| Install | the previous bundle is moved aside, not deleted — a failure at any point puts it back |
| Rewire | hooks, login item and command links all point at what was just installed, and are checked afterwards to say so |
| Protect | your chime and mute settings and your terminal pairings are hashed before and after, and every hook that is not ours must come out byte-identical |

**The app is installed outside the repository, on purpose.** It used to *be* the repo's `build/`
directory, so the install was only ever as stable as the folder it was built in — renaming that
folder broke the hook entries, the login item and the build cache at once, and none of them said so.
The repo can now be renamed, moved or deleted without any of that following.

`./install.sh` still exists for wiring hooks only, without building or moving anything.

| Flag | Effect |
|---|---|
| `--dry-run` | print the resulting hooks block, change nothing |
| `--settings PATH` | wire a project `.claude/settings.json` instead of the user one |
| `--login-item` | also start the app at login (opt-in; nothing is installed automatically) |
| `--no-launch` | wire the hooks without starting the app |
| `--link-dir DIR` | put the command symlinks somewhere other than `~/.local/bin` |
| `--no-path` | put nothing on `PATH`; use the full paths inside the bundle instead |

### The commands, on your PATH

The binaries live inside the app bundle, which is not a directory anybody has on their `PATH`. So
`install.sh` symlinks the five commands this README uses — `aa-status`, `aa-emit`, `aa-bridge`,
`aa-session`, `aa-roam` — into `~/.local/bin`. Without that step every `aa-status` in these pages is
a `command not found`, which is exactly what it used to be.

Three rules, so this cannot damage anything:

- **A name is not ownership.** A link is replaced only if it already points into an
  `AgentWarden.app` bundle. A real file, a directory, or somebody else's symlink that happens to be
  called `aa-status` is reported and left exactly where it is.
- **Being on disk is not being reachable.** If `~/.local/bin` is not on your `PATH`, the installer
  says so and prints the line to add, rather than leaving you to find out later.
- **`uninstall.sh` takes back only what it put there**, by the same test — a link that no longer
  points into a bundle of ours is listed, not deleted.

`AgentWarden` itself is deliberately not linked. It is an app you open, not a command you type.

**No restarts.** Claude Code watches its settings file and reloads hooks automatically, so sessions
that are already running pick up the new entries without being closed. And because Agent Warden
reads Claude Code's own session registry, sessions that were already running show up immediately —
before any of them has fired a hook.

### macOS permissions you will be asked for

| Prompt | When | If you decline |
|---|---|---|
| **Automation** (control iTerm2 / Terminal) | The first time you click a card for an iTerm2 or Apple Terminal session | You get the app-only path plus the Copy button. Nothing else breaks. |
| **Login item** | Only if you pass `--login-item` | The app simply does not start at login |

No Accessibility permission, no Screen Recording, no window-list access. The bubble is placed by
configuration and dragging, not by inspecting other apps' windows.

### Uninstall

```bash
./uninstall.sh              # removes only our hook entries, backs up first
./uninstall.sh --purge      # also deletes the local data directory (asks first)
```

It also releases any roam sleep block, removes the root power helper, restores your previous status
line, and takes the command symlinks back out — each by the same ownership rules as the hooks, and
each saying so rather than doing it quietly. If it cannot restore the status line it refuses and
changes nothing rather than guessing, and tells you which backup holds your original.

Ownership comes from a manifest, per settings file, as exact command strings — and from nothing
else. There is **no fallback that infers ownership from a binary's name**: a hook of yours that runs
a different executable also called `aa-emit`, with different arguments, is not ours and is never
touched. Neither is any group or key that was in the file before we arrived.

Without a manifest we cannot know what is ours, so `uninstall` **refuses and changes nothing**,
listing the candidate commands so you can remove them by hand. `manage-hooks.py status` names them
as *unowned lookalikes*, never as owned. Install replaces only entries that are byte-identical to
the ones it is about to write, which is what keeps a second install idempotent without guessing.

The login item is owned the same way: its plist is parsed and must match our exact `Label` **and**
`ProgramArguments` before it is overwritten or removed. A grep for the label would match a comment
or somebody else's agent.

## Roam

Close the laptop, put it in a bag, and the session keeps running. That is the whole feature, and
everything below exists because the obvious way to build it — turn the machine's sleep off — is the
one that flattens a battery in a bag and loses the work.

**Turn it on from the menu.** Right-click the bubble, or use the menu-bar item: **Turn roam on**.
The bubble grows a halo while roam is live, and the same item turns it off. The item explains
itself rather than only greying out:

| It says | Meaning |
|---|---|
| `Turn roam on` / `Turn roam off` | Ready, or live. |
| `Roam needs the power helper — run install.sh` | The privileged helper is not installed, so there is nothing that can hold the lid-close block. |
| `Retry roam — another tool holds sleep` | Something else already set the machine's sleep block — a `sudo pmset -a disablesleep 1` by hand, or a roam plugin still installed. Warden will not take over a setting it did not set. Clear the other hold and click again; the item stays clickable so a retry is always available. |

**The status line says so too.** Roam adds a `🎒 roam on` segment to your Claude Code status line,
so a session in another window can tell at a glance that the lid is safe to close. The installer
takes over your existing status line to add it — carrying every other segment through verbatim,
including hand-added ones — and shows you the resulting wrapper and asks before writing anything.

**It ends itself before the battery does.** While roaming, Warden checks the charge on every lease
heartbeat. At or below `roamBatteryThreshold` (10% by default, in `config.json`), on battery, it
tells you what is happening, gives the sleep block back, confirms that landed, and *then* sleeps
the Mac — in that order, so you never get told the machine is asleep when it is in fact awake on a
dying charge. It also refuses to *start* below that threshold rather than starting and sleeping ten
seconds later.

**How it holds the machine awake.** `SleepDisabled` is a single machine-wide setting only root can
write, with no notion of who set it. So a small root daemon — `aa-powerd`, installed by
`install.sh` into `/Library/PrivilegedHelperTools` — owns it and hands it out as an exclusive
lease that Warden must renew every 10 seconds. Nothing else in Agent Warden needs privilege, and
nothing else lives there. If Warden crashes, is killed, or simply stops renewing, the lease expires
and the daemon clears the block: the dangerous state cannot outlive the thing that asked for it.

### If your Mac will not sleep

The repair, printed by the installer and repeated here because it is the one thing worth having
written down somewhere you can find without the app:

```bash
sudo pmset -a disablesleep 0
```

That clears the machine-wide block by hand. You need it only if the helper was stopped or removed
while it was holding one — `launchd` will not restart a *hung* daemon, and the daemon's own startup
reconciliation cannot run until it starts again. `./uninstall.sh` releases the block before it
removes the helper, and warns if `SleepDisabled` is still set afterwards.

Check the current state at any time:

```bash
pmset -g | grep SleepDisabled     # 0 = your Mac sleeps normally
aa-roam status                    # what Warden thinks, and whether the file is stale
```

**Known limits, stated rather than papered over.** The lease authenticates a *user*, not this
application: any process running as you can hold the block. Power assertions are advisory and macOS
may override them under a thermal or low-power emergency. And roam keeps the machine awake — it
does not keep the *network* up; a session that needs a connection still needs one.

## Querying it without a screenshot

```bash
aa-status              # one line per waiting session, for a human
aa-status --json       # the same, as JSON (schema 3)
aa-status --waiting    # exit status only — see below
```

Read-only: it never starts the app, never drains the queue, never writes.

```
--waiting exit codes
  0  something is waiting for you
  1  nothing is waiting, and the answer can be trusted
  2  cannot tell — app not running, state stale or unreadable, or process inspection unavailable
```

Three codes, not two, because "nothing is waiting" and "I could not find out" must not look the
same to a script.

```json
{
  "app": { "running": true, "livenessVerified": true, "stateReadable": true,
           "fresh": true, "stateAgeSeconds": 3.1, "unprocessedEvents": 0 },
  "counts": { "pending": 1, "snoozed": 0, "sessionsTracked": 3, "sessionsWorking": 2,
              "sessionsWaitingOnBackground": 1, "sessionsUncertain": 0,
              "sessionsAwaitingFirstHook": 0 },
  "pending": [
    { "kind": "approval", "source": "reported", "project": "agent-attention",
      "sessionID": "9f2c4a1b-full-stable-id", "displayID": "9f2c4a1b",
      "reason": "Permission needed: Bash", "waitingSeconds": 92, "occurrences": 2,
      "clickTarget": "appOnly", "openLabel": "Open Ghostty",
      "process": "alive", "terminal": "Ghostty" }
  ],
  "sessions": [
    { "project": "exec-cashflow-truth", "state": "backgroundWaiting", "hookCoverage": true,
      "attention": "known",
      "background": { "availability": "reported", "running": 1, "failed": 0, "crons": 0,
                      "types": ["shell"], "ageSeconds": 41.0,
                      "waiting": true, "confirmedComplete": false,
                      "summary": "Paused — 1 background shell still running" } }
  ],
  "warnings": []
}
```

- `running` is `true` / `false` / **`null`**. Null means process inspection was refused — under a
  sandbox that cannot call `sysctl`, a live app must not be reported as dead. `livenessVerified`
  says whether the check ran at all.
- `process` is `alive` / `dead` / `unknown` / `unidentified`, for the same reason.
- `sessionID` is the full, stable id. `displayID` is short and for display only — short ids collide.
- `stateReadable` is false when the saved queue exists but will not parse; a recent mtime on a
  broken file is not freshness.
- `sessions[].background` reports what the last `Stop` left running: counts and task *types* only,
  never a task's description, command or prompt. `availability: "unknown"` means the evidence was
  missing or unreadable — neither busy nor finished.
- `sessions[].hookCoverage` and `sessions[].attention` answer different questions. The first is
  "have we ever heard from it"; the second is "does it need you *now*", and is one of `waiting`,
  `none`, `uncertain` or `awaitingFirstHook`. Having heard from a session once does not make its
  current state known — a session whose turn ended without confirmation reads `uncertain`, raises a
  warning, and makes `answerIsTrustworthy` false. `pending: 0` alone is never the whole answer.
- A session waiting on background work is **not** in `pending`, so `--waiting` stays quiet for it;
  it is counted in `counts.sessionsWaitingOnBackground`.
- `warnings` carries plain sentences for anything that makes the numbers misleading.

There is no MCP server. The JSON above is the whole interface, and a shell command is a cheaper way
for an assistant to reach it than a protocol. Any assistant querying this still spends its own
context on the answer, which is why the payload is compact.

## How it works

```
Claude Code hook  ──▶  aa-emit  (a hook adds a process spawn; see the report for measurements)
                          ├─▶ sessions/<id>.json   heartbeat, overwritten every hook
                          └─▶ spool/<ts>-<id>.json only for alerts and lifecycle
                                       │
AgentWarden.app  ◀── directory watcher + 15 s sweep
   AttentionEngine  ──▶ bubble badge · anchored panel · menu bar · optional speech · state.json
                                       │
aa-status  ◀── reads state.json + app.json, never writes
```

Two directories instead of a socket, because the emitter must never depend on the app running and
nothing may be lost if either side restarts. Spool files are deleted only *after* the state that
absorbed them is safely on disk, so a crash mid-cycle replays rather than loses.

Everything lives in `~/Library/Application Support/AgentAttention/` (mode `0700`, files `0600`).
Set `AGENT_ATTENTION_HOME` to move it.

### What is stored

Session id, working directory, the Claude process id and its start time, the tty, `TERM_PROGRAM`
and the terminal's bundle path, tmux pane, plus a one-line reason. Prompt text, assistant messages,
tool inputs and transcript paths are never read or written — there are tests that fail if they
appear on disk. There is no transcript ingestion of any kind. The hook's own message text is not
stored unless you turn on `includeHookMessages`.

## Settings

`config.json` in the data directory — edited live by the menu, or by hand (picked up on the next
sweep). Missing keys fall back to defaults; out-of-range numbers are clamped rather than obeyed.

| Key | Default | Meaning |
|---|---|---|
| `bubbleEnabled` | `true` | show the floating bubble |
| `bubblePlacement` | bottom right, 24 / 120 | `{corner, offsetX, offsetY}`, inward from that corner |
| `bubbleSize` | 56 | diameter, clamped 40–96 |
| `backgroundEvidenceTTLSeconds` | 1800 | after this, a `Stop` reading of background work stops counting as current |
| `snoozeDurationSeconds` | 600 | default snooze |
| `maxItemAgeSeconds` | 28800 | an untouched ask expires after this |
| `staleSessionSeconds` | 43200 | a silent session record is dropped after this |
| `sweepIntervalSeconds` | 15 | maintenance tick |
| `soundEnabled` | `true` | the master audio switch — off means no sound at all, including speech |
| `speechEnabled` | `false` | local macOS speech, silent whenever `soundEnabled` is off |
| `chimeEnabled` | `false` | the two-note attention chime, silent whenever `soundEnabled` is off |
| `orchestrationContractPath` | *(unset)* | the document holding your working agreement. No default, no assumed vault |
| `includeHookMessages` | `false` | store the hook's message text as the reason |
| `maxVisibleCards` | 4 | rows before "+N more tracked" (the list never shows fewer than 8) |
| `notifyOnWorkComplete` / `notifyOnIdle` | `true` | whether that class of generic signal may show a card |

Both toggles suppress an **alert** and nothing else. With `notifyOnWorkComplete` off, the app still
reads the `Stop` payload, still records what the turn left running, still shows the session as
paused or uncertain in the panel, and still raises a **failed** background task as an error. Turning
off completion alerts is not turning off errors, and it is not asking the app to stop knowing
things.

`stallThresholdSeconds`, `wakeGraceSeconds` and `stallDetectionEnabled` are still accepted so an
existing `config.json` loads unchanged, but nothing reads them. Setting `stallDetectionEnabled` to
`true` does nothing — the inference it controlled no longer exists.

**The gear and the speaker in the panel header** edit the same file. The speaker is the master
switch: muted means no sound at all, chime or speech. Muting does not forget what was wanted —
unmuting restores exactly what was already set, and never announces anything that happened while it
was off. A setting that fails to write says so in the panel instead of appearing to have been
applied.

**The chime.** Under Settings: *Attention chime* to switch it on, and *Preview chime* to hear it
once without changing anything. It sounds for a genuine ask — a question, an approval, a stage
decision, a handoff, an error — and never for a finished turn, an idle prompt or a suspected stall.
One sound per waiting episode, a floor of four seconds between sounds, nothing for an ask that was
already resolved by the time the cycle ended, and nothing at all while muted: silence is not a
backlog, so unmuting plays none of it. The waveform is two sine notes generated in this process —
no bundled track, no audio service, no permission prompt, no recording.

Because "Sound" on its own only ever meant "not muted", the settings menu says so plainly when
sound is on but neither the chime nor speech is: *No alert sound is on — turn on Attention chime to
hear one.*

A dismissal is not time-based: it holds until the session does real work again.

## Development

```bash
./Scripts/release.sh         # build, gate, install, restart — the whole pipeline
./Scripts/release.sh --no-install   # build and gate only; leave the running app alone
./Scripts/test.sh            # 970 unit and integration tests across 96 suites
./Scripts/smoke-test.sh      # 204 assertions against the real binaries and the real installer
./Scripts/build-app.sh       # build the .app bundle

build/AgentWarden.app/Contents/MacOS/AgentWarden --uicheck    # 502 checks on the bubble and panel (more with --png)
build/AgentWarden.app/Contents/MacOS/AgentWarden --selftest   # one refresh cycle, as text
build/AgentWarden.app/Contents/MacOS/aa-emit --doctor         # what a hook would record here
build/AgentWarden.app/Contents/MacOS/aa-status --json         # the queue, read-only
/usr/bin/python3 Scripts/manage-hooks.py status               # what is wired right now
```

Tests, the smoke test and the UI check redirect `AGENT_ATTENTION_HOME` and operate on throwaway
settings files, so they never read or write real session data, real configuration or real hooks.

## Status and roadmap

A working prototype for local use. Signing, notarisation and distribution are out of scope — see
[BACKLOG.md](BACKLOG.md).

Deferred, in order:

1. **Phase two — background shells, monitors and processes** left running by coding agents. Not
   started.
2. **Two-way, voice-assisted project management.** A future possibility only, and only through a
   supported, permitted session-control integration with reliable routing, explicit
   acknowledgement, authorised replies and verified progress. Nothing about it is implemented, and
   phase one deliberately stays read-only.

Several on-screen behaviours have **not** been verified on a live machine — how the panel looks,
floating over full-screen spaces, the AppleScript paths for iTerm2 / Apple Terminal / tmux, and the
Automation prompt. [IMPLEMENTATION_REPORT.md](IMPLEMENTATION_REPORT.md) §8 lists exactly which.

MIT licensed — see [LICENSE](LICENSE).
