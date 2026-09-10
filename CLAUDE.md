# Agent Warden — doctrine for agents working here

A personal macOS menu-bar tool that watches local Claude Code sessions. Public, MIT, one user,
no SLA, no customers. **Nothing here is production infrastructure and no change here is urgent.**

Read this before the three setup questions, not after.

## Proportion is the first rule (overrides global § Work Mode)

Default to **fast mode, current branch, light review**. Do not ask the three setup questions for
work that fits the default — state the default in one line and start.

Ask, or step up to detailed mode and full review, **only** for work that touches one of these:

| Earns the heavy process | Why |
|---|---|
| Anything running as root (`aa-powerd`, LaunchDaemon plists, `pmset`) | A bug can leave a machine unable to sleep, or awake on battery until it dies |
| `install.sh`, `uninstall.sh`, `Scripts/install-*`, `Scripts/manage-*.py` | They edit files the user cannot regenerate — `settings.json`, status-line wrappers, hooks |
| The bridge or daemon wire protocol | Other processes speak it; a change is not local |
| A change the user calls risky | Their judgment, not yours |

Everything else — UI, panel, naming, discovery, config fields, docs, tests — is fast mode. A
one-file change is fast mode even if it looks interesting.

## Process budget (overrides global § Work Mode, § How to engage the team)

These are caps, not targets. Under them, no permission needed. To exceed one, say which cap and
why in a single line, then proceed.

- **No plan document** unless the work creates or restructures **5+ files**. Fast mode gets a
  bullet checkpoint in chat and nothing on disk.
- **No spec document** unless the work is on the heavy list above.
- **No SDD workspace, ledger, task briefs, review packages or per-task review diffs.** They exist
  for multi-day multi-agent projects, which this repo does not have.
- **No new `IMPLEMENTATION_REPORT.md`-scale artefact.** That file is a historical record; do not
  grow it and do not write a sibling. Findings worth keeping go in `BACKLOG.md` § Known rough
  edges as a bullet.
- **Max 2 fix rounds** per review. A third round means the review is wrong, the task is wrong, or
  the design is — say which and stop, rather than looping.
- **Subagents: at most 2 per task**, and only for genuinely parallel independent work. One
  reviewer is a review; three reviewers is theatre. Never a reviewer per file.
- **Documentation prose must not exceed the code it describes.** If it is heading that way, the
  code needs a better name, not a longer explanation.

Calibration, from the one time this went wrong: roam mode shipped ~2,900 lines of code
accompanied by ~11,400 lines of spec, plan, ledger, briefs and review packages, across 15 tasks
and ~27 review dispatches. It replaced a 1,644-line shell plugin. The code was fine. The process
cost a full day. Do not repeat it.

## Verification — three gates, and one is not enough

```bash
bash Scripts/test.sh                              # unit + integration
.build/debug/AgentAttention --uicheck             # native UI assertions
bash Scripts/smoke-test.sh                        # real binaries, real installer, sandboxed
```

- **Use `Scripts/test.sh`, never bare `swift test`.** This machine has only the Command Line
  Tools, so `swift test` dies with `no such module 'Testing'`. The script adds the flags that fix
  it.
- **The `--uicheck` assertions are not in the unit suite.** They live in
  `Sources/AgentAttentionApp/UICheck.swift`. A rename that satisfies every unit test can still
  break one — this has happened.
- After touching fixture strings, identifiers or user-facing text, run all three.
- `swift build` warnings about unused `map` results are pre-existing. Do not "fix" them as a
  side quest.

## Hard boundaries

- **Nothing outside this repository and `/tmp` may be created, modified or deleted — by you, or
  by anything you run.** Not `~/.claude`, not `~/dev`, not another repo, not a stray worktree.
  This includes running an installer's code "to see what it does": read it instead. Two
  unrecoverable incidents came from agents obeying the letter of a narrower rule.
- **You have no tty, so you cannot run `sudo`.** Print the exact command and ask the user to run
  it with `! <command>`.
- **This repo is public.** Never introduce a private project name, client ticket key, branch
  prefix carrying someone's initials, or a real home path — in code, tests, comments, docs or
  commit messages. Code and test fixtures use `atlas`, `orbit-*`, `task42`, `dev/<branch>`,
  `alex`; `README.md` uses `acme-*` and `feat/…`. The two vocabularies are both fine — do not
  "harmonise" one into the other, that is churn with no reader benefit.
  `ai.wundamental.*` is the one deliberate exception: it is the app's own reverse-DNS identity
  (bundle id, queue labels, daemon socket path) and changing it breaks installed builds.
- Global § Git Commits & Pushes still applies in full and is **not** overridden here: no commit,
  push or amend unless the user asks.

## House style

The codebase has a voice. Match it or the diff reads as foreign.

- **Doc comments explain why, from observed behaviour**, not what the function does. They cite
  the real failure that motivated the code.
- **Test names are sentences describing a behaviour**, not method names — `@Test("A renamed tab
  renames its row")`. Suites are `@Suite("Reading the tab bar")`.
- **Tests use swift-testing** (`import Testing`, `@Test`, `#expect`), never XCTest.
- Comments are sparse and load-bearing. No section banners, no restating the line below.
- User-facing strings say "Agent Warden"; modules, bundle id and data directory still say
  `AgentAttention`. Leave that alone.

## Layout

| Path | What |
|---|---|
| `Sources/AgentAttentionCore` | Pure logic, no AppKit — where testable behaviour belongs |
| `Sources/AgentAttentionApp` | The app: bubble, panel, services, and the UI self-check |
| `Sources/AAPowerd` | Root daemon owning `SleepDisabled` as a heartbeat-renewed lease |
| `Sources/AARoam`, `Sources/AAEmit`, `Sources/AAStatus`, `Sources/AABridge`, `Sources/AASession` | Small CLIs on the user's PATH |
| `Scripts` | Build, test, install, hook and status-line management |
| `BACKLOG.md` | Known rough edges and deliberate non-goals — read before proposing "improvements" |

`README.md` § Development lists the full command set. `BACKLOG.md` records what is deliberately
not built; check it before building something it already declined.
