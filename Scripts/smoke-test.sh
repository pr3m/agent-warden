#!/bin/bash
# End-to-end smoke test against the real binaries and the real installer.
#
# Everything runs inside temporary directories: AGENT_ATTENTION_HOME is redirected, and every
# settings file the installer touches is a throwaway copy. Your real Claude Code configuration and
# your real session data are never read or written.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${SMOKE_CONFIG:-debug}"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ✔ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ✘ %s\n' "$1"; }

check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

contains() { # contains <description> <needle> <haystack>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (missing '$2')" ;;
  esac
}

missing() { # missing <description> <needle> <haystack>
  case "$3" in
    *"$2"*) bad "$1 (unexpectedly found '$2')" ;;
    *) ok "$1" ;;
  esac
}

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" >/dev/null || { echo "build failed"; exit 1; }
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
EMIT="$BIN/aa-emit"
APP="$BIN/AgentAttention"
AASTATUS="$BIN/aa-status"
SESSION="$BIN/aa-session"

# `pwd -P` normalises the path: TMPDIR often ends in a slash, and the app reports the canonical
# form, so a raw mktemp path would not compare equal.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agent-warden-smoke.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export AGENT_ATTENTION_HOME="$WORK/home"
# Point registry discovery at an empty fixture for the whole run. Without this a smoke test would
# list the real Claude Code sessions on this machine.
export AGENT_WARDEN_CLAUDE_HOME="$WORK/claude-home"
mkdir -p "$AGENT_WARDEN_CLAUDE_HOME/sessions" "$AGENT_WARDEN_CLAUDE_HOME/projects"

emit() { printf '%s' "$1" | "$EMIT" "${@:2}"; }

# A process this test owns that the app will accept as a Claude session: the right executable name,
# a real pid, and a real birth time.
#
# It has to be *compiled here*, not copied. Copying a system binary such as /bin/sleep strips its
# code signature, and macOS then kills the copy on launch (exit 137, SIGKILL) — which has nothing to
# do with this app and would make a section fail for a reason that is not about the product.
#
# Given arguments it runs a command as its child and then stays alive, so anything that command
# spawns has this process as an ancestor. That is what lets a hook be fired with a *known* Claude
# identity instead of inheriting whatever happened to launch the test.
compile_claude_fixture() { # compile_claude_fixture <output path> <section, for the message>
  mkdir -p "$(dirname "$1")"
  cat > "$WORK/fake-claude.c" <<'CEOF'
/* Stands in for a running Claude process: the right executable name, a real pid, and a real birth
   time. With no arguments it simply lives. With `<seconds> <command> [args…]` it runs the command
   as a child, waits for it, and then stays alive for that many seconds — so the command, and
   everything it spawns, has a genuine `claude` ancestor to be identified by. It does nothing else:
   no hooks, no files, no terminal. */
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc > 2) {
        pid_t child = fork();
        if (child == 0) { execv(argv[2], &argv[2]); _exit(127); }
        int status = 0;
        waitpid(child, &status, 0);
        sleep((unsigned)atoi(argv[1]));
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }
    sleep(600);
    return 0;
}
CEOF
  if ! cc -o "$1" "$WORK/fake-claude.c" 2>/dev/null; then
    bad "could not compile the Claude fixture helper (cc missing?) — section $2 cannot run"
    return 1
  fi
}

echo
echo "== 1. Hook emitter writes heartbeats and spool records =="

emit '{"hook_event_name":"SessionStart","session_id":"smoke-alpha","cwd":"'"$WORK"'/alpha","source":"startup"}' --signal sessionStart
emit '{"hook_event_name":"SessionStart","session_id":"smoke-beta","cwd":"'"$WORK"'/beta","source":"startup"}' --signal sessionStart
check "two session heartbeats" "2" "$(ls "$AGENT_ATTENTION_HOME/sessions" | wc -l | tr -d ' ')"
check "two spooled lifecycle events" "2" "$(ls "$AGENT_ATTENTION_HOME/spool" | wc -l | tr -d ' ')"

for _ in 1 2 3 4 5; do
  emit '{"hook_event_name":"PostToolUse","session_id":"smoke-alpha","cwd":"'"$WORK"'/alpha","tool_name":"Read","tool_output":"lots of output"}' --signal activity
done
check "ordinary work adds no spool files" "2" "$(ls "$AGENT_ATTENTION_HOME/spool" | wc -l | tr -d ' ')"
check "ordinary work does not add heartbeat files" "2" "$(ls "$AGENT_ATTENTION_HOME/sessions" | wc -l | tr -d ' ')"
check "data files are private to this user" "600" "$(stat -f '%OLp' "$AGENT_ATTENTION_HOME/sessions"/*.json | head -1)"
check "the data directory is private too" "700" "$(stat -f '%OLp' "$AGENT_ATTENTION_HOME")"

echo
echo "== 2. Explicit signals reach the queue =="

emit '{"hook_event_name":"Notification","session_id":"smoke-alpha","cwd":"'"$WORK"'/alpha","notification_type":"permission_prompt","message":"Claude needs your permission"}' --kind approval
emit '{"hook_event_name":"Stop","session_id":"smoke-beta","cwd":"'"$WORK"'/beta","background_tasks":[],"session_crons":[],"last_assistant_message":"SECRET-ASSISTANT-TEXT"}' --kind workComplete

OUT="$("$APP" --selftest)"
contains "alpha waits on approval" "[approval] alpha" "$OUT"
contains "beta reports work complete" "[workComplete] beta" "$OUT"
contains "two sessions tracked" "sessions tracked: 2" "$OUT"
contains "pending count is 2" "pending: 2" "$OUT"

echo
echo "== 3. Nothing sensitive reaches disk =="
DISK="$(cat "$AGENT_ATTENTION_HOME"/sessions/*.json "$AGENT_ATTENTION_HOME"/state.json 2>/dev/null)"
missing "no assistant text on disk" "SECRET-ASSISTANT-TEXT" "$DISK"
missing "no tool output on disk" "lots of output" "$DISK"
missing "no hook message text by default" "Claude needs your permission" "$DISK"
contains "session identity is on disk" "smoke-alpha" "$DISK"

echo
echo "== 4. One wait produces one card, however many signals describe it =="
emit '{"hook_event_name":"Notification","session_id":"smoke-alpha","cwd":"'"$WORK"'/alpha","notification_type":"permission_prompt","message":"Claude needs your permission"}' --kind approval
emit '{"hook_event_name":"Notification","session_id":"smoke-alpha","cwd":"'"$WORK"'/alpha","notification_type":"idle_prompt","message":"Claude is waiting for your input"}' --kind idle
OUT="$("$APP" --selftest)"
contains "the follow-up signals are counted, not requeued" "seen 3x" "$OUT"
contains "still only two pending" "pending: 2" "$OUT"
contains "the more blocking description wins" "[approval] alpha" "$OUT"

echo
echo "== 5. Work resuming clears the alert =="
sleep 1
emit '{"hook_event_name":"PostToolUse","session_id":"smoke-alpha","cwd":"'"$WORK"'/alpha","tool_name":"Bash"}' --signal activity
OUT="$("$APP" --selftest)"
missing "alpha is no longer waiting" "[approval] alpha" "$OUT"
contains "beta is still waiting" "[workComplete] beta" "$OUT"
contains "one pending" "pending: 1" "$OUT"

echo
echo "== 6. SessionEnd removes the session and its record =="
emit '{"hook_event_name":"SessionEnd","session_id":"smoke-beta","cwd":"'"$WORK"'/beta","reason":"logout"}' --signal sessionEnd
OUT="$("$APP" --selftest)"
contains "nothing pending" "pending: 0" "$OUT"
contains "one session left" "sessions tracked: 1" "$OUT"
check "beta's heartbeat file is gone" "1" "$(ls "$AGENT_ATTENTION_HOME/sessions" | wc -l | tr -d ' ')"

echo
echo "== 6b. A turn that ends with work still running is paused, not finished =="
# Real emitter, real spool, real engine. The Stop payload carries the task arrays Claude Code
# documents, including the description and command fields that must never be stored.
emit '{"hook_event_name":"Stop","session_id":"smoke-bg","cwd":"'"$WORK"'/bg","background_tasks":[{"id":"t1","type":"shell","status":"running","description":"SECRET-TASK-DESC","command":"SECRET-TASK-CMD"}],"session_crons":[]}' --kind workComplete
OUT="$("$APP" --selftest)"
contains "the session is reported as waiting on background work" "waiting on background work: 1" "$OUT"
contains "and what it is waiting on is a count, not task text" "1 background shell still running" "$OUT"
missing "a paused turn does not claim completion" "[workComplete] bg" "$OUT"
contains "nothing is asked of the user" "pending: 0" "$OUT"
DISK="$(cat "$AGENT_ATTENTION_HOME"/sessions/*.json "$AGENT_ATTENTION_HOME"/state.json 2>/dev/null)"
missing "no task description reaches disk" "SECRET-TASK-DESC" "$DISK"
missing "no task command reaches disk" "SECRET-TASK-CMD" "$DISK"

BG_JSON="$("$AASTATUS" --json)"
contains "status counts it apart from attention" '"sessionsWaitingOnBackground" : 1' "$BG_JSON"
contains "status says the evidence was reported" '"availability" : "reported"' "$BG_JSON"
contains "status keeps only the task type" '"shell"' "$BG_JSON"
missing "status leaks no task text" "SECRET-TASK" "$BG_JSON"
# Exit 2, not 0: nothing is being asked of you, and the app is not running here either. What
# matters is that a background pause is never reported as "something is waiting for you" (0).
"$AASTATUS" --waiting; check "--waiting never reports a background pause as waiting for you" "2" "$?"

# The same session finishing for real. Empty arrays are the only confirmed completion.
sleep 1
emit '{"hook_event_name":"Stop","session_id":"smoke-bg","cwd":"'"$WORK"'/bg","background_tasks":[],"session_crons":[]}' --kind workComplete
OUT="$("$APP" --selftest)"
contains "an empty task list is a real completion" "[workComplete] bg" "$OUT"
contains "and it is no longer paused" "waiting on background work: 0" "$OUT"

# An older Claude Code, or a payload without the arrays at all. A separate session, because merging
# into the completed episode above would keep that card's wording rather than replace it.
emit '{"hook_event_name":"Stop","session_id":"smoke-bg2","cwd":"'"$WORK"'/bg2"}' --kind workComplete
OUT="$("$APP" --selftest)"
missing "missing task evidence never becomes a completion card" "[workComplete] bg2" "$OUT"
# bg's own confirmed completion is still in the queue; the point is that bg2 adds nothing to it.
contains "and it raises nothing at all — uncertainty is passive" "pending: 1" "$OUT"
contains "the session records the gap rather than guessing" "background=unknown" "$OUT"
contains "and it is not treated as a pause either" "waiting on background work: 0" "$OUT"

emit '{"hook_event_name":"SessionEnd","session_id":"smoke-bg","cwd":"'"$WORK"'/bg","reason":"logout"}' --signal sessionEnd
emit '{"hook_event_name":"SessionEnd","session_id":"smoke-bg2","cwd":"'"$WORK"'/bg2","reason":"logout"}' --signal sessionEnd
"$APP" --selftest >/dev/null

echo
echo "== 6g. A turn that hands something back is a request, even with work still running =="
# Run through the *installed* hook arguments — `Stop --kind workComplete`, `SubagentStop --signal
# activity` — so this proves an existing installation behaves correctly with no settings rewrite.
emit '{"hook_event_name":"Stop","session_id":"smoke-handoff","cwd":"'"$WORK"'/handoff","background_tasks":[{"status":"running","type":"shell"}],"session_crons":[],"last_assistant_message":"Done.\n\n**I need from you:** decide whether the grid goes full width."}' --kind workComplete
OUT="$("$APP" --selftest)"
contains "a final handoff is raised as waiting for you" "[handoff] handoff" "$OUT"
missing "and never as a generic completion" "[workComplete] handoff" "$OUT"
missing "the request's own words are not on the card by default" "full width" "$OUT"
DISK="$(cat "$AGENT_ATTENTION_HOME"/state.json "$AGENT_ATTENTION_HOME"/sessions/*.json 2>/dev/null)"
missing "nor on disk" "full width" "$DISK"
missing "and neither is the rest of the final message" "decide whether" "$DISK"

# A child finishing must not close the parent's request.
emit '{"hook_event_name":"SubagentStop","session_id":"smoke-handoff","cwd":"'"$WORK"'/handoff"}' --signal activity
OUT="$("$APP" --selftest)"
contains "a subagent stopping leaves the parent waiting" "[handoff] handoff" "$OUT"

# The parent itself carrying on does close it.
sleep 1
emit '{"hook_event_name":"PostToolUse","session_id":"smoke-handoff","cwd":"'"$WORK"'/handoff","tool_name":"Bash"}' --signal activity
OUT="$("$APP" --selftest)"
missing "the parent resuming resolves it" "[handoff] handoff" "$OUT"

# The case that was correctly quiet before, and must stay quiet.
emit '{"hook_event_name":"Stop","session_id":"smoke-quiet-handoff","cwd":"'"$WORK"'/quiet","background_tasks":[{"status":"running","type":"shell"}],"session_crons":[],"last_assistant_message":"All done.\n\n**I need from you:** nothing, carry on."}' --kind workComplete
OUT="$("$APP" --selftest)"
missing "a footer that asks for nothing raises nothing" "[handoff] quiet" "$OUT"
missing "and no completion either, because work is still running" "[workComplete] quiet" "$OUT"
contains "it is still shown as paused on its own work" "quiet" "$OUT"

echo
echo "== 6c. Elapsed silence never becomes an alert =="
# The clearest statement of the rule: a session that goes quiet mid-work stays quiet, however long
# it has been. There is no threshold left to cross.
emit '{"hook_event_name":"UserPromptSubmit","session_id":"smoke-quiet","cwd":"'"$WORK"'/quiet"}' --signal activity
"$APP" --selftest >/dev/null
# Backdate every timestamp in the saved queue by six hours and re-run. Nothing may appear.
/usr/bin/python3 - "$AGENT_ATTENTION_HOME/state.json" <<'PY'
import datetime, re, sys
path = sys.argv[1]
raw = open(path).read()
def shift(match):
    stamp = datetime.datetime.strptime(match.group(0)[:23], "%Y-%m-%dT%H:%M:%S.%f")
    return (stamp - datetime.timedelta(hours=6)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + match.group(0)[23:]
open(path, "w").write(re.sub(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:?\d\d", shift, raw))
PY
OUT="$("$APP" --selftest)"
missing "six hours of silence raises nothing" "suspectedStall" "$OUT"
contains "and the queue is still empty" "pending: 0" "$OUT"
missing "status invents no stall either" "suspectedStall" "$("$AASTATUS" --json)"
emit '{"hook_event_name":"SessionEnd","session_id":"smoke-quiet","cwd":"'"$WORK"'/quiet","reason":"logout"}' --signal sessionEnd
"$APP" --selftest >/dev/null

echo
echo "== 6d. Branch and name come from the directory, not from a stale stamp =="
# A real repository, created here. `git init` writes only inside this temp directory.
REPO="$WORK/branch-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main >/dev/null 2>&1
git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1
git -C "$REPO" checkout -q -b cs/red645-own-capital >/dev/null 2>&1

emit '{"hook_event_name":"UserPromptSubmit","session_id":"smoke-branch","cwd":"'"$REPO"'"}' --signal activity
OUT="$("$APP" --selftest)"
contains "the branch is read from the working directory" "branch=cs/red645-own-capital/git" "$OUT"
missing "and the launch-time stamp is not what is shown" "branch=main/git" "$OUT"

# A real directory that is not a repository, and a directory that is not there at all. Both are
# reported as themselves; neither ever becomes a branch name.
mkdir -p "$WORK/plain-dir"
emit '{"hook_event_name":"UserPromptSubmit","session_id":"smoke-norepo","cwd":"'"$WORK"'/plain-dir"}' --signal activity
emit '{"hook_event_name":"UserPromptSubmit","session_id":"smoke-gone","cwd":"'"$WORK"'/not-there"}' --signal activity
OUT="$("$APP" --selftest)"
contains "a directory with no repository says so" "branch=notARepository/git" "$OUT"
# `denied` is a failure to read, not a fact about the branch, so it is reported as availability
# rather than dressed up as a reading. It is still said out loud, and still never becomes a name.
contains "a directory we cannot enter says that instead" "branch=denied" "$OUT"
missing "and a failure never turns into a branch name" "branch=denied/git" "$OUT"
missing "and neither is ever labelled with a branch name" "branch=main/" "$OUT"

# Nothing in the repository was touched.
check "the repository is still on its branch" "cs/red645-own-capital" "$(git -C "$REPO" --no-optional-locks branch --show-current)"
check "and its working tree is clean" "" "$(git -C "$REPO" status --porcelain)"

emit '{"hook_event_name":"SessionEnd","session_id":"smoke-branch","cwd":"'"$REPO"'","reason":"logout"}' --signal sessionEnd
emit '{"hook_event_name":"SessionEnd","session_id":"smoke-norepo","cwd":"'"$WORK"'/plain-dir","reason":"logout"}' --signal sessionEnd
emit '{"hook_event_name":"SessionEnd","session_id":"smoke-gone","cwd":"'"$WORK"'/not-there","reason":"logout"}' --signal sessionEnd
"$APP" --selftest >/dev/null

echo
echo "== 6e. Recent conversation is on demand, read-only, and only the session you name =="
CTX_HOME="$WORK/ctx-home"
mkdir -p "$CTX_HOME/projects/-w-alpha"
CTX_ID="aaaaaaaa-1111-2222-3333-444444444444"
OTHER_ID="bbbbbbbb-1111-2222-3333-444444444444"
/usr/bin/python3 - "$CTX_HOME/projects/-w-alpha" "$CTX_ID" "$OTHER_ID" <<'PYEOF'
import json, os, sys
d, mine, other = sys.argv[1], sys.argv[2], sys.argv[3]
def rec(t, text, session, extra=None):
    r = {"type": t, "sessionId": session, "timestamp": "2026-09-06T10:00:00.000Z",
         "message": {"role": t, "content": [{"type": "text", "text": text}]}}
    if extra: r["message"]["content"] = extra
    return json.dumps(r)
lines = [
    rec("user", "rework the export to v3", mine),
    rec("assistant", "SECRET-THINKING-MUST-NOT-APPEAR", mine,
        extra=[{"type": "thinking", "thinking": "SECRET-THINKING-MUST-NOT-APPEAR"},
               {"type": "text", "text": "done, schema switched"}]),
    rec("assistant", "SOMEONE-ELSES-CONVERSATION", other),
]
open(os.path.join(d, mine + ".jsonl"), "w").write("\n".join(lines) + "\n")
PYEOF

MISSING_ID="dddddddd-1111-2222-3333-444444444444"

# Identity comes first, and it is identity of a *live process*, not of a record. A hook fired from
# an ordinary shell has no Claude ancestor to identify, so its session is correctly refused as
# unverified — which made this section pass or fail depending on whether the test itself happened to
# be launched from inside Claude Code. That is a property of the launcher, not of the product.
#
# So both sessions are pinned here: their hooks are fired as descendants of one live fixture process
# this test owns, and the collector identifies it exactly as it would a real Claude — same code
# path, same pid, same real birth time. Nothing is hand-written into the queue and no gate is
# relaxed; the section simply stops depending on who ran it.
CTX_CLAUDE="$WORK/ctx-claude-bin/claude"
if compile_claude_fixture "$CTX_CLAUDE" "6e"; then
  cat > "$WORK/ctx-emits.sh" <<EOF
#!/bin/sh
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"$CTX_ID","cwd":"$WORK/alpha"}' | "$EMIT" --signal activity
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"$MISSING_ID","cwd":"$WORK/alpha"}' | "$EMIT" --signal activity
EOF
  chmod +x "$WORK/ctx-emits.sh"
  # Stays alive for the rest of this section, so the sessions it fathered remain verifiable.
  "$CTX_CLAUDE" 300 /bin/sh "$WORK/ctx-emits.sh" &
  CTX_CLAUDE_PID=$!
  trap 'kill "$CTX_CLAUDE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
  for _ in $(seq 1 100); do
    if [ -f "$AGENT_ATTENTION_HOME/sessions/$CTX_ID.json" ] &&
       [ -f "$AGENT_ATTENTION_HOME/sessions/$MISSING_ID.json" ]; then break; fi
    /bin/sleep 0.1
  done
fi
"$APP" --selftest >/dev/null

CTX_IDENTITY="$(/usr/bin/python3 -c 'import json,sys
state = json.load(open(sys.argv[1]))
print(json.dumps(state["sessions"].get(sys.argv[2], {}).get("identity", {})))' "$AGENT_ATTENTION_HOME/state.json" "$CTX_ID" 2>/dev/null)"
check "the session is pinned to the live fixture process this test owns" "${CTX_CLAUDE_PID:-0}" \
  "$(printf '%s' "$CTX_IDENTITY" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("claudePID",0))' 2>/dev/null)"
contains "and to that process's own birth time, read the way the app reads it" '"claudePIDStartedAt"' "$CTX_IDENTITY"

CTX_BEFORE="$(ls "$AGENT_ATTENTION_HOME/spool" | wc -l | tr -d ' ')"
CTX="$(AGENT_WARDEN_CLAUDE_HOME="$CTX_HOME" "$AASTATUS" --session "$CTX_ID" --context 2>/dev/null)"
check "reading a conversation exits 0" "0" "$?"
contains "it quotes what the person asked" "rework the export to v3" "$CTX"
contains "and what the assistant answered" "done, schema switched" "$CTX"
missing "thinking never appears" "SECRET-THINKING-MUST-NOT-APPEAR" "$CTX"
missing "another session's conversation never appears" "SOMEONE-ELSES-CONVERSATION" "$CTX"
contains "the attention state is reported separately and as authoritative" "from hooks, and authoritative" "$CTX"
contains "identity is stated before any contents" "identity: tracked" "$CTX"
contains "queue freshness is reported apart from conversation freshness" "queue fresh:" "$CTX"
check "asking for a conversation drains nothing" "$CTX_BEFORE" "$(ls "$AGENT_ATTENTION_HOME/spool" | wc -l | tr -d ' ')"

# A session the app does not track: refused outright, with no contents read, whatever file exists.
/usr/bin/python3 -c 'import json,sys,os
d,i=sys.argv[1],sys.argv[2]
open(os.path.join(d,i+".jsonl"),"w").write(json.dumps({"type":"user","sessionId":i,"userType":"external","message":{"role":"user","content":"UNTRACKED_SENTINEL"}})+"\n")' "$CTX_HOME/projects/-w-alpha" "cccccccc-9999-9999-9999-999999999999"
UNTRACKED="$(AGENT_WARDEN_CLAUDE_HOME="$CTX_HOME" "$AASTATUS" --session "cccccccc-9999-9999-9999-999999999999" --context 2>/dev/null)"
check "a session the app does not track exits 5" "5" "$?"
missing "and its conversation is never read, though the file is right there" "UNTRACKED_SENTINEL" "$UNTRACKED"

# Tracked, but with no transcript of its own. The extra refresh is deliberate: a later heartbeat
# merge must not quietly replace the pinned identity with an unidentified one, or this section would
# go back to depending on who ran it.
"$APP" --selftest >/dev/null
REPINNED="$(/usr/bin/python3 -c 'import json,sys
state = json.load(open(sys.argv[1]))
print(state["sessions"].get(sys.argv[2], {}).get("identity", {}).get("claudePID", 0))' "$AGENT_ATTENTION_HOME/state.json" "$MISSING_ID" 2>/dev/null)"
check "a later refresh keeps that pinned identity" "${CTX_CLAUDE_PID:-0}" "$REPINNED"
AGENT_WARDEN_CLAUDE_HOME="$CTX_HOME" "$AASTATUS" --session "$MISSING_ID" --context >/dev/null 2>&1
check "a tracked session with no transcript exits 3" "3" "$?"
AGENT_WARDEN_CLAUDE_HOME="$CTX_HOME" "$AASTATUS" --context >/dev/null 2>&1
check "no session id exits 2" "2" "$?"
AGENT_WARDEN_CLAUDE_HOME="$CTX_HOME" "$AASTATUS" --session "../../etc/passwd" --context >/dev/null 2>&1
check "a path pretending to be an id exits 2" "2" "$?"
CTX_JSON="$(AGENT_WARDEN_CLAUDE_HOME="$CTX_HOME" "$AASTATUS" --session "$CTX_ID" --context --json)"
contains "the JSON says where it read from" '"availability" : "read"' "$CTX_JSON"
contains "and keeps attention apart from the transcript" '"attention"' "$CTX_JSON"
missing "and leaks nothing it excluded" "SECRET-THINKING-MUST-NOT-APPEAR" "$CTX_JSON"

# This section's own process, and nothing else, released once it is finished with.
if [ -n "${CTX_CLAUDE_PID:-}" ]; then
  kill "$CTX_CLAUDE_PID" 2>/dev/null
  wait "$CTX_CLAUDE_PID" 2>/dev/null
  trap 'rm -rf "$WORK"' EXIT
fi

echo
echo "== 6f. A confirmed terminal link is honoured, and only while it still means something =="
# The link file is written directly here, exactly as the pairing window would write it. Nothing in
# this section talks to Ghostty: the live focus is the one thing only a person at the machine can
# confirm, and a script pretending otherwise would be the false confidence this feature avoids.
emit '{"hook_event_name":"UserPromptSubmit","session_id":"eeeeeeee-1111-2222-3333-444444444444","cwd":"'"$WORK"'/alpha"}' --signal activity
"$APP" --selftest >/dev/null
LINK_PID="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sessions"]["eeeeeeee-1111-2222-3333-444444444444"]["identity"].get("claudePID",0))' "$AGENT_ATTENTION_HOME/state.json")"
/usr/bin/python3 - "$AGENT_ATTENTION_HOME/pairings.json" "$LINK_PID" <<'PYEOF'
import json, sys
path, pid = sys.argv[1], int(sys.argv[2])
json.dump({"schema": 1, "pairings": [{
    "schema": 1, "sessionID": "eeeeeeee-1111-2222-3333-444444444444",
    "claudePID": pid, "claudePIDStartedAt": 1.0, "tty": "/dev/ttys004",
    "terminalAppBundleID": "com.mitchellh.ghostty",
    "terminalAppPID": 999999, "terminalAppStartedAt": 1.0,
    "terminalID": "term-smoke", "tabID": "tab-1", "windowID": "win-1",
    "terminalName": "alpha", "pairedAt": "2026-09-06T10:00:00.000+00:00",
    "provenance": "userConfirmed",
}]}, open(path, "w"))
PYEOF

LINK_JSON="$("$AASTATUS" --json)"
contains "the link is reported with the tab the user confirmed" '"terminalID" : "term-smoke"' "$LINK_JSON"
contains "and says a person is why it exists" '"provenance" : "userConfirmed"' "$LINK_JSON"
contains "a link that cannot be checked from here is not called valid" '"usable" : false' "$LINK_JSON"
missing "and exact navigation is never claimed on the strength of a saved link alone" '"clickTarget" : "exactTab"' "$LINK_JSON"
missing "the link file holds no transcript, token or socket" "messagingSocketPath" "$(cat "$AGENT_ATTENTION_HOME/pairings.json")"
OUT="$("$APP" --selftest)"
contains "the link is carried through with its provenance" "link=term-smoke/userConfirmed" "$OUT"

# The session ends: its link is retired, and nothing else is disturbed.
PENDING_BEFORE="$("$APP" --selftest | grep -c '^  \[')"
emit '{"hook_event_name":"SessionEnd","session_id":"eeeeeeee-1111-2222-3333-444444444444","cwd":"'"$WORK"'/alpha","reason":"logout"}' --signal sessionEnd
OUT="$("$APP" --selftest)"
contains "a link for an ended session is retired" "retired terminal link(s): 1" "$OUT"
check "and the file now holds none" "0" "$(/usr/bin/python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["pairings"]))' "$AGENT_ATTENTION_HOME/pairings.json")"
# Written by the app itself, so the mode is the app's own.
check "the link file the app writes is private to this user" "600" "$(stat -f '%OLp' "$AGENT_ATTENTION_HOME/pairings.json")"
check "retiring a link disturbed no pending request" "$PENDING_BEFORE" "$("$APP" --selftest | grep -c '^  \[')"

echo
echo "== 7. Malformed input is survivable =="
printf 'not json at all' | "$EMIT"; check "emitter exits 0 on garbage stdin" "0" "$?"
printf '' | "$EMIT"; check "emitter exits 0 on empty stdin" "0" "$?"
echo '{ broken' > "$AGENT_ATTENTION_HOME/spool/0000000000000-broken.json"
OUT="$("$APP" --selftest)"
contains "the bad file is quarantined" "quarantined:" "$OUT"
check "quarantine holds it" "1" "$(ls "$AGENT_ATTENTION_HOME/quarantine" | wc -l | tr -d ' ')"

echo
echo "== 8. A crash before saving does not lose an alert =="
emit '{"hook_event_name":"Notification","session_id":"smoke-alpha","cwd":"'"$WORK"'/alpha","notification_type":"permission_prompt","message":"x"}' --kind approval
check "the event is on disk before anything reads it" "1" "$(ls "$AGENT_ATTENTION_HOME/spool" | wc -l | tr -d ' ')"
# Make saving impossible. A read-only file would not do it — the save renames a temp file into
# place and rename(2) does not consult the destination's mode — so replace it with a directory.
rm -f "$AGENT_ATTENTION_HOME/state.json"
mkdir "$AGENT_ATTENTION_HOME/state.json"
OUT="$("$APP" --selftest 2>&1)"
rmdir "$AGENT_ATTENTION_HOME/state.json"
check "the spool file is kept when the save failed" "1" "$(ls "$AGENT_ATTENTION_HOME/spool" | wc -l | tr -d ' ')"
OUT="$("$APP" --selftest)"
contains "the alert arrives once the save succeeds" "[approval] alpha" "$OUT"
check "and the file is released afterwards" "0" "$(ls "$AGENT_ATTENTION_HOME/spool" | wc -l | tr -d ' ')"

echo
echo "== 9. State survives a restart =="
OUT="$("$APP" --selftest)"   # a second, independent process reads the saved state
contains "the queue is still there after a fresh process" "[approval] alpha" "$OUT"

echo
echo "== 10. The read-only status interface =="
JSON="$("$AASTATUS" --json)"
contains "status reports its schema" '"schema" : 3' "$JSON"
contains "status knows the app is not running" '"running" : false' "$JSON"
contains "status says its liveness check worked" '"livenessVerified" : true' "$JSON"
contains "status marks the queue as not fresh" '"fresh" : false' "$JSON"
contains "status confirms the saved queue parsed" '"stateReadable" : true' "$JSON"
contains "status warns rather than implying all is well" "is not running" "$JSON"
contains "status lists the waiting project" '"project" : "alpha"' "$JSON"
contains "status distinguishes reported from suspected" '"source" : "reported"' "$JSON"
contains "status carries the full session id" '"sessionID" : "smoke-alpha"' "$JSON"
contains "status carries a separate display id" '"displayID"' "$JSON"
contains "status states what Open will do" '"openLabel"' "$JSON"
# The collector's own liveness depends on who invoked it: a hook fired outside Claude Code has no
# Claude ancestor to identify, so "unidentified" is correct there. Assert the vocabulary here; the
# values themselves are pinned by the fixture below.
PROC_STATE="$(printf '%s' "$JSON" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["pending"][0]["process"])')"
case "$PROC_STATE" in
  alive|dead|unknown|unidentified) ok "status reports process state as a word, not a boolean ($PROC_STATE)" ;;
  *) bad "status reports process state as a word, not a boolean (got $PROC_STATE)" ;;
esac
"$AASTATUS" --waiting; check "--waiting exits 0 while something waits" "0" "$?"
TEXT="$("$AASTATUS")"
contains "the text summary is readable" "NOT RUNNING" "$TEXT"
contains "the text summary names the project" "alpha" "$TEXT"
BEFORE="$(ls "$AGENT_ATTENTION_HOME/spool" | wc -l | tr -d ' ')"
"$AASTATUS" --json >/dev/null; "$AASTATUS" >/dev/null
check "asking for status changes nothing" "$BEFORE" "$(ls "$AGENT_ATTENTION_HOME/spool" | wc -l | tr -d ' ')"

echo "  — tri-state liveness, from a fixture rather than from whoever ran this —"
/bin/sleep 120 &
LIVE_PID=$!
cp "$AGENT_ATTENTION_HOME/state.json" "$AGENT_ATTENTION_HOME/state.beforefixture.json"
/usr/bin/python3 Scripts/write-liveness-fixture.py "$AGENT_ATTENTION_HOME/state.json" "$LIVE_PID" >/dev/null
STATES="$("$AASTATUS" --json | /usr/bin/python3 -c 'import json,sys;print(",".join(sorted(p["process"] for p in json.load(sys.stdin)["pending"])))')"
check "a live pid reads alive, a gone pid dead, an unidentified one neither" "alive,dead,unidentified" "$STATES"
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null
mv "$AGENT_ATTENTION_HOME/state.beforefixture.json" "$AGENT_ATTENTION_HOME/state.json"

echo "  — an unavailable answer is not a quiet one —"
# Nothing waiting, but nothing watching either: --waiting must not report "all clear".
mv "$AGENT_ATTENTION_HOME/state.json" "$AGENT_ATTENTION_HOME/state.saved.json"
echo '{"version":2,"items":[],"sessions":{},"recentEventIDs":[],"savedAt":"2026-01-01T00:00:00.000Z"}' > "$AGENT_ATTENTION_HOME/state.json"
"$AASTATUS" --waiting; check "--waiting exits 2 when the app is not running" "2" "$?"
contains "and says why" "not running" "$("$AASTATUS")"

echo '{{{ broken' > "$AGENT_ATTENTION_HOME/state.json"
BROKEN="$("$AASTATUS" --json)"
contains "an unreadable queue is not called fresh" '"stateReadable" : false' "$BROKEN"
contains "and it is explained" "could not be read" "$BROKEN"
"$AASTATUS" --waiting; check "--waiting exits 2 on an unreadable queue" "2" "$?"
mv "$AGENT_ATTENTION_HOME/state.saved.json" "$AGENT_ATTENTION_HOME/state.json"

echo "== 10b. Sessions that were already running are discovered =="
# A process that will pass verification: a real live pid whose executable is named `claude` and
# whose birth time matches what the record claims.
# It has to be *compiled here*, not copied. Copying a system binary such as /bin/sleep strips its
# code signature, and macOS then kills the copy on launch (exit 137, SIGKILL) — which has nothing to
# do with this app and would make the section fail for a reason that is not about the product.
FAKE_CLAUDE="$WORK/fake-claude-bin/claude"
compile_claude_fixture "$FAKE_CLAUDE" "10b"
"$FAKE_CLAUDE" &
CLAUDE_PID=$!
PROC_START="$(/bin/date '+%a %b %e %H:%M:%S %Y')"
NOW_MS="$(/usr/bin/python3 -c 'import time;print(int(time.time()*1000))')"
mkdir -p "$WORK/discovered-project"

/usr/bin/python3 - "$AGENT_WARDEN_CLAUDE_HOME/sessions" "$CLAUDE_PID" "$PROC_START" "$NOW_MS" "$WORK/discovered-project" <<'PYEOF'
import json, sys, os
sessions, pid, proc_start, now_ms, cwd = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5]

def write(name, record):
    json.dump(record, open(os.path.join(sessions, name), "w"))

write(f"{pid}.live.json", {
    "sessionId": "discovered-live", "pid": pid, "procStart": proc_start,
    "cwd": cwd, "name": "already running", "nameSource": "derived",
    "version": "2.1.261", "status": "busy",
    "startedAt": now_ms - 3600000, "updatedAt": now_ms,
    "messagingSocketPath": "/tmp/never-touch-me.sock",
})
# A record whose process is long gone.
write("999999.dead.json", {
    "sessionId": "discovered-dead", "pid": 999999, "procStart": proc_start,
    "cwd": "/tmp/gone", "startedAt": now_ms, "updatedAt": now_ms,
})
open(os.path.join(sessions, "broken.json"), "w").write("{ not json")
# A peer token. Opening this would be a security problem.
open(os.path.join(sessions, f"{pid}.live.key"), "w").write("SECRET-PEER-TOKEN")
PYEOF

OUT="$("$APP" --selftest)"
contains "the registry is scanned" "registry: present=true" "$OUT"
contains "the live session is verified" "verified=1" "$OUT"
contains "the dead one is rejected" "processGone" "$OUT"
contains "the malformed record is counted" "malformed=1" "$OUT"
contains "the discovered session is listed" "state=discovered" "$OUT"
contains "and marked as having no hook coverage" "hookCoverage=false" "$OUT"
# Earlier sections legitimately left their own session working with an item pending, so
# assert about the discovered session specifically rather than about the global counts.
missing "discovery raises no attention of its own" "already running" "$OUT"
check "the peer token is untouched" "SECRET-PEER-TOKEN" "$(cat "$AGENT_WARDEN_CLAUDE_HOME/sessions/$CLAUDE_PID.live.key")"

DJSON="$("$AASTATUS" --json)"
contains "status flags it as awaiting a first hook" '"attention" : "awaitingFirstHook"' "$DJSON"
contains "status says hook coverage is false" '"hookCoverage" : false' "$DJSON"
contains "status counts it apart from working" '"sessionsAwaitingFirstHook" : 1' "$DJSON"
contains "status carries registry status verbatim" '"registryStatus" : "busy"' "$DJSON"
contains "status reports discovery freshness separately" '"lastScanAt"' "$DJSON"
contains "status warns that its state is unknown, not quiet" "not yet reported through a hook" "$DJSON"
DSTATE="$(printf '%s' "$DJSON" | /usr/bin/python3 -c '
import json,sys
d=json.load(sys.stdin)
x=[e for e in d["sessions"] if e["sessionID"]=="discovered-live"][0]
print(x["state"], x["hookCoverage"], any(p["sessionID"]=="discovered-live" for p in d["pending"]))')"
check "a discovered session is never working, covered or pending" "discovered False False" "$DSTATE"

echo "  — a real hook merges into the same session —"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"discovered-live","cwd":"'"$WORK"'/discovered-worktree","tool_name":"Bash"}' | "$EMIT" --signal activity
OUT="$("$APP" --selftest)"
check "still one discovered session, not two" "1" "$(printf '%s' "$OUT" | grep -c 'discovered-live\|discovered' || true)"
contains "the hook takes over the state" "hookCoverage=true" "$OUT"
contains "and the hook's directory wins over the registry's" "discovered-worktree" "$OUT"

echo "  — and it goes when its process does —"
kill "$CLAUDE_PID" 2>/dev/null
wait "$CLAUDE_PID" 2>/dev/null
rm -f "$AGENT_WARDEN_CLAUDE_HOME/sessions/$CLAUDE_PID.live.json"
OUT="$("$APP" --selftest)"
missing "the dead session is gone" "discovered-live" "$OUT"

echo "== 11. The panel and menu-bar item build correctly =="
if UI_OUT="$("$APP" --uicheck 2>&1)"; then
  ok "UI check passed ($(printf '%s' "$UI_OUT" | grep -c '✔') assertions)"
else
  bad "UI check failed"
  printf '%s\n' "$UI_OUT" | sed 's/^/    /'
fi

echo
echo "== 12. The emitter reports what a hook would record =="
DOCTOR="$(printf '%s' '{"hook_event_name":"Stop","session_id":"doctor-1","cwd":"'"$WORK"'/alpha"}' | "$EMIT" --doctor)"
contains "doctor reports the session id" "doctor-1" "$DOCTOR"
contains "doctor reports the storage root" "$AGENT_ATTENTION_HOME" "$DOCTOR"
contains "doctor reports the click-through confidence" "click-through" "$DOCTOR"
contains "doctor offers the resume fallback" "claude --resume doctor-1" "$DOCTOR"

echo
echo "== 13. The installer preserves existing hooks =="
FAKE_SETTINGS="$WORK/settings.json"
cat > "$FAKE_SETTINGS" <<'JSON'
{
  "outputStyle": "founder",
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "bash /somebody/elses/notify.sh stop", "timeout": 5 }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "python3 /somebody/elses/guard.py" }] }
    ],
    "Notification": [
      { "hooks": [
          { "type": "command", "command": "echo 'aa-emit is a great name for a binary'" },
          { "type": "command", "command": "/opt/tools/aa-emit-wrapper/run.sh" }
      ] }
    ]
  }
}
JSON
cp "$FAKE_SETTINGS" "$WORK/settings.original.json"
chmod 640 "$FAKE_SETTINGS"

/usr/bin/python3 Scripts/manage-hooks.py install --settings "$FAKE_SETTINGS" --emit-path "$EMIT" >/dev/null
AFTER="$(cat "$FAKE_SETTINGS")"
contains "the other Stop hook survives install" "/somebody/elses/notify.sh" "$AFTER"
contains "the other PreToolUse matcher survives install" "/somebody/elses/guard.py" "$AFTER"
contains "unrelated settings survive install" "founder" "$AFTER"
contains "our hook is present" "aa-emit --kind approval" "$AFTER"
check "a backup was written" "1" "$(ls "$WORK" | grep -c 'settings.json.agent-warden-backup')"
check "the settings file keeps its permissions" "640" "$(stat -f '%OLp' "$FAKE_SETTINGS")"

echo
echo "== 14. A foreign hook that merely mentions aa-emit is not ours =="
contains "a foreign echo mentioning aa-emit survives install" "great name for a binary" "$AFTER"
contains "a foreign wrapper path containing aa-emit survives install" "/opt/tools/aa-emit-wrapper/run.sh" "$AFTER"

/usr/bin/python3 Scripts/manage-hooks.py install --settings "$FAKE_SETTINGS" --emit-path "$EMIT" >/dev/null
check "installing twice leaves one entry per wired hook" "16" \
  "$(/usr/bin/python3 -c 'import json,sys,shlex,os;d=json.load(open(sys.argv[1]));print(sum(1 for e in d["hooks"].values() for g in e for h in g["hooks"] if os.path.basename(shlex.split(h.get("command",""))[0] if h.get("command") else "")=="aa-emit"))' "$FAKE_SETTINGS")"

/usr/bin/python3 Scripts/manage-hooks.py uninstall --settings "$FAKE_SETTINGS" >/dev/null
FINAL="$(/usr/bin/python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),indent=2,sort_keys=True))' "$FAKE_SETTINGS")"
ORIGINAL="$(/usr/bin/python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),indent=2,sort_keys=True))' "$WORK/settings.original.json")"
check "uninstall restores the file exactly, foreign aa-emit mentions included" "$ORIGINAL" "$FINAL"

echo
echo "== 15. Paths with spaces and metacharacters are quoted =="
SPACED_DIR="$WORK/dir with space & sym"
mkdir -p "$SPACED_DIR"
cp "$EMIT" "$SPACED_DIR/aa-emit"
SPACED_SETTINGS="$WORK/spaced-settings.json"
echo '{"hooks":{}}' > "$SPACED_SETTINGS"
/usr/bin/python3 Scripts/manage-hooks.py install --settings "$SPACED_SETTINGS" --emit-path "$SPACED_DIR/aa-emit" >/dev/null
QUOTED="$(/usr/bin/python3 -c '
import json,sys,shlex,os
d=json.load(open(sys.argv[1]))
cmd=d["hooks"]["Stop"][0]["hooks"][0]["command"]
print(os.path.basename(shlex.split(cmd)[0]))' "$SPACED_SETTINGS")"
check "a space-and-ampersand path round-trips through the shell command" "aa-emit" "$QUOTED"
RUNS="$(/usr/bin/python3 -c '
import json,subprocess,sys
d=json.load(open(sys.argv[1]))
cmd=d["hooks"]["Stop"][0]["hooks"][0]["command"]
p=subprocess.run(["/bin/sh","-c",cmd+" --version"],capture_output=True,text=True)
print(p.stdout.strip())' "$SPACED_SETTINGS")"
contains "the installed command actually runs through a shell" "aa-emit" "$RUNS"
/usr/bin/python3 Scripts/manage-hooks.py uninstall --settings "$SPACED_SETTINGS" >/dev/null
check "and uninstalls cleanly" '{"hooks": {}}' "$(/usr/bin/python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))))' "$SPACED_SETTINGS")"

echo
echo "== 16. Ownership is scoped to one settings file =="
A="$WORK/target-a.json"; B="$WORK/target-b.json"
echo '{}' > "$A"; echo '{}' > "$B"
/usr/bin/python3 Scripts/manage-hooks.py install --settings "$A" --emit-path "$EMIT" >/dev/null
/usr/bin/python3 Scripts/manage-hooks.py install --settings "$B" --emit-path "$EMIT" >/dev/null
/usr/bin/python3 Scripts/manage-hooks.py uninstall --settings "$A" >/dev/null
check "uninstalling one target empties it" "0" \
  "$(/usr/bin/python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sum(len(g["hooks"]) for e in (d.get("hooks") or {}).values() for g in e))' "$A")"
check "the other target keeps its entries" "16" \
  "$(/usr/bin/python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sum(len(g["hooks"]) for e in (d.get("hooks") or {}).values() for g in e))' "$B")"
contains "the manifest still owns the second target" "target-b.json" "$(cat "$AGENT_ATTENTION_HOME/install-manifest.json")"
/usr/bin/python3 Scripts/manage-hooks.py uninstall --settings "$B" >/dev/null

echo
echo "== 16b. Ownership is never inferred from a binary's name =="
# The exact case that was reported: a different executable that happens to be called aa-emit.
FOREIGN_DIR="$WORK/unrelated-tool"
mkdir -p "$FOREIGN_DIR"
cp "$EMIT" "$FOREIGN_DIR/aa-emit"
OWN="$WORK/ownership.json"
/usr/bin/python3 - "$OWN" "$FOREIGN_DIR/aa-emit" <<'PYEOF'
import json, sys
path, foreign = sys.argv[1], sys.argv[2]
json.dump({"outputStyle": "founder", "hooks": {"Stop": [
    {"hooks": [{"type": "command", "command": foreign + " --custom", "timeout": 5}]}
]}}, open(path, "w"), indent=2)
PYEOF
cp "$OWN" "$OWN.original"
OWN_MANIFEST="$WORK/ownership-manifest.json"

/usr/bin/python3 Scripts/manage-hooks.py install --settings "$OWN" --emit-path "$EMIT" --manifest "$OWN_MANIFEST" > "$WORK/own-install.log" 2>&1
contains "install leaves a foreign aa-emit executable alone" "unrelated-tool/aa-emit --custom" "$(cat "$OWN")"
contains "and says so" "left alone" "$(cat "$WORK/own-install.log")"

/usr/bin/python3 Scripts/manage-hooks.py uninstall --settings "$OWN" --manifest "$OWN_MANIFEST" >/dev/null
contains "uninstall leaves it alone too" "unrelated-tool/aa-emit --custom" "$(cat "$OWN")"
check "and restores the file exactly" "$(/usr/bin/python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))' "$OWN.original")" \
      "$(/usr/bin/python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))' "$OWN")"

echo "  — without a manifest we do not know what is ours —"
/usr/bin/python3 Scripts/manage-hooks.py install --settings "$OWN" --emit-path "$EMIT" --manifest "$OWN_MANIFEST" >/dev/null
cp "$OWN" "$OWN.installed"
rm -f "$OWN_MANIFEST"
/usr/bin/python3 Scripts/manage-hooks.py uninstall --settings "$OWN" --manifest "$OWN_MANIFEST" > "$WORK/own-nomanifest.log" 2>&1
check "uninstall refuses when the manifest is missing" "1" "$?"
contains "and explains why" "Refusing to guess" "$(cat "$WORK/own-nomanifest.log")"
check "and changes nothing" "$(cat "$OWN.installed")" "$(cat "$OWN")"

echo '{ not a manifest' > "$OWN_MANIFEST"
/usr/bin/python3 Scripts/manage-hooks.py uninstall --settings "$OWN" --manifest "$OWN_MANIFEST" > "$WORK/own-corrupt.log" 2>&1
check "uninstall refuses when the manifest is corrupt" "1" "$?"
check "and still changes nothing" "$(cat "$OWN.installed")" "$(cat "$OWN")"

STATUS_OUT="$(/usr/bin/python3 Scripts/manage-hooks.py status --settings "$OWN" --manifest "$OWN_MANIFEST")"
contains "status names lookalikes without claiming them" "unowned lookalikes" "$STATUS_OUT"
contains "status reports no owned commands without a manifest" "owned commands: 0" "$STATUS_OUT"

echo
echo "== 16c. The login item is owned by its contents, not by a grep =="
LA="$WORK/dev.agentwarden.plist"
LABEL="dev.agentwarden"
PROG="$WORK/AgentWarden"
check "absent is absent" "absent" "$(/usr/bin/python3 Scripts/launch-agent.py check "$LA" "$LABEL" "$PROG")"
/usr/bin/python3 Scripts/launch-agent.py write "$LA" "$LABEL" "$PROG" >/dev/null
check "what we wrote is ours" "ours" "$(/usr/bin/python3 Scripts/launch-agent.py check "$LA" "$LABEL" "$PROG")"

# Somebody else's agent that merely mentions our label must not be adopted.
/usr/bin/python3 - "$WORK/foreign.plist" "$LABEL" <<'PYEOF'
import plistlib, sys
plistlib.dump({"Label": "com.example.other",
               "ProgramArguments": ["/bin/echo", "mentions " + sys.argv[2]],
               "RunAtLoad": True},
              open(sys.argv[1], "wb"))
PYEOF
check "a foreign agent mentioning our label is foreign" "foreign" \
      "$(/usr/bin/python3 Scripts/launch-agent.py check "$WORK/foreign.plist" "$LABEL" "$PROG")"
/usr/bin/python3 Scripts/launch-agent.py write "$WORK/foreign.plist" "$LABEL" "$PROG" >/dev/null 2>&1
check "and writing over it is refused" "1" "$?"
/usr/bin/python3 Scripts/launch-agent.py remove "$WORK/foreign.plist" "$LABEL" "$PROG" >/dev/null 2>&1
check "and removing it is refused" "1" "$?"
check "so it is still there" "1" "$(ls "$WORK/foreign.plist" | wc -l | tr -d ' ')"

# Same label, different program: still not ours.
/usr/bin/python3 Scripts/launch-agent.py write "$LA" "$LABEL" "$WORK/SomethingElse" >/dev/null 2>&1
check "same label but a different program is refused" "1" "$?"
/usr/bin/python3 Scripts/launch-agent.py remove "$LA" "$LABEL" "$PROG" >/dev/null
check "our own agent removes cleanly" "absent" "$(/usr/bin/python3 Scripts/launch-agent.py check "$LA" "$LABEL" "$PROG")"

echo "== 17. The installer refuses to damage a broken settings file =="
echo '{ not json' > "$WORK/broken-settings.json"
/usr/bin/python3 Scripts/manage-hooks.py install --settings "$WORK/broken-settings.json" --emit-path "$EMIT" >/dev/null 2>&1
check "install fails loudly on invalid JSON" "1" "$?"
check "the broken file is left alone" '{ not json' "$(cat "$WORK/broken-settings.json")"

echo "  — concurrent modification —"
CONC="$WORK/concurrent.json"
echo '{"hooks":{}}' > "$CONC"
/usr/bin/python3 - "$ROOT/Scripts/manage-hooks.py" "$CONC" "$EMIT" <<'PY'
import json, subprocess, sys, runpy, os
script, settings, emit = sys.argv[1], sys.argv[2], sys.argv[3]
# Rewrite the file after the script has read it but before it writes: patch read_raw to mutate.
marker = '    """Timestamped, collision-proof, and with the original file\'s mode preserved."""'
assert marker in open(script).read(), "smoke test patch anchor moved"
source = open(script).read().replace(
    marker,
    marker + "\n    open(path, 'w').write('{\"changed\":true}')",
    1,
)
patched = settings + ".patched.py"
open(patched, "w").write(source)
result = subprocess.run(
    ["/usr/bin/python3", patched, "install", "--settings", settings, "--emit-path", emit],
    capture_output=True, text=True,
)
print("EXIT", result.returncode)
print(open(settings).read().strip())
PY
CONC_OUT="$(/usr/bin/python3 -c 'import sys;print(open(sys.argv[1]).read().strip())' "$CONC")"
check "a file changed underneath us is not clobbered" '{"changed":true}' "$CONC_OUT"

# --- The orchestration contract, through the installed CLI ---------------------------------------
#
# Everything here uses throwaway fixtures in this test's own home. No real agreement is read, and
# no file is written except the ones created a line before they are read.
echo
echo "Orchestration contract (aa-status --contract)"
CONTRACT_HOME="$WORK/contract-home"
mkdir -p "$CONTRACT_HOME"
CONTRACT_DOC="$WORK/agreement.md"
printf '# Working agreement\n\nUser sets goals.\n' > "$CONTRACT_DOC"

# Nothing selected: a fact, with its own exit code, and the monitor still answers normally.
AGENT_ATTENTION_HOME="$CONTRACT_HOME" "$AASTATUS" --contract >/dev/null 2>&1
check "no selection has its own exit code" "1" "$?"
AGENT_ATTENTION_HOME="$CONTRACT_HOME" "$AASTATUS" --json >/dev/null 2>&1
check "and the ordinary status query is unaffected by having no contract" "0" "$?"

# Selected and readable.
printf '{"orchestrationContractPath":"%s"}' "$CONTRACT_DOC" > "$CONTRACT_HOME/config.json"
CONTRACT_JSON="$(AGENT_ATTENTION_HOME="$CONTRACT_HOME" "$AASTATUS" --contract --json)"
contains "a selected document is reported as available" '"availability" : "available"' "$CONTRACT_JSON"
contains "with a revision over its exact bytes" '"revision"' "$CONTRACT_JSON"
case "$CONTRACT_JSON" in *'"content"'*) bad "metadata must not carry the body";; *) ok "and no body unless it is asked for";; esac

CONTRACT_BODY="$(AGENT_ATTENTION_HOME="$CONTRACT_HOME" "$AASTATUS" --contract --content)"
contains "--content returns the document" "User sets goals." "$CONTRACT_BODY"

# A fresh edit is seen on the next request: nothing is cached between invocations.
REV_ONE="$(AGENT_ATTENTION_HOME="$CONTRACT_HOME" "$AASTATUS" --contract --json | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["revision"])')"
printf '# Working agreement\n\nUser sets scope.\n' > "$CONTRACT_DOC"
REV_TWO="$(AGENT_ATTENTION_HOME="$CONTRACT_HOME" "$AASTATUS" --contract --json | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["revision"])')"
if [ "$REV_ONE" != "$REV_TWO" ]; then ok "an edit changes the revision on the very next request"; else bad "a cached agreement was served"; fi

# Missing: still selected, and it says so.
mv "$CONTRACT_DOC" "$CONTRACT_DOC.away"
CONTRACT_GONE="$(AGENT_ATTENTION_HOME="$CONTRACT_HOME" "$AASTATUS" --contract --json)"
contains "a missing document is reported as missing" '"availability" : "missing"' "$CONTRACT_GONE"
contains "and stays selected" '"selectedPath"' "$CONTRACT_GONE"
mv "$CONTRACT_DOC.away" "$CONTRACT_DOC"
contains "restoring it is enough" '"availability" : "available"' \
  "$(AGENT_ATTENTION_HOME="$CONTRACT_HOME" "$AASTATUS" --contract --json)"

# A named pipe must not hang the query.
mkfifo "$WORK/agreement.pipe"
printf '{"orchestrationContractPath":"%s"}' "$WORK/agreement.pipe" > "$CONTRACT_HOME/config.json"
PIPE_JSON="$(AGENT_ATTENTION_HOME="$CONTRACT_HOME" timeout 10 "$AASTATUS" --contract --json)"
contains "a named pipe is refused rather than waited on" '"notRegularFile"' "$PIPE_JSON"

# Reading never writes: neither the document nor the configuration.
printf '{"orchestrationContractPath":"%s"}' "$CONTRACT_DOC" > "$CONTRACT_HOME/config.json"
DOC_BEFORE="$(shasum -a 256 "$CONTRACT_DOC" | cut -d" " -f1)"
CFG_BEFORE="$(shasum -a 256 "$CONTRACT_HOME/config.json" | cut -d" " -f1)"
AGENT_ATTENTION_HOME="$CONTRACT_HOME" "$AASTATUS" --contract --content >/dev/null
check "querying leaves the document byte-for-byte unchanged" "$DOC_BEFORE" "$(shasum -a 256 "$CONTRACT_DOC" | cut -d" " -f1)"
check "and leaves the configuration exactly as it was" "$CFG_BEFORE" "$(shasum -a 256 "$CONTRACT_HOME/config.json" | cut -d" " -f1)"

echo
echo "== 12. The session relay renders a real stream and survives doing it =="
# This section exists for a crash that no unit test could have caught. Top-level code in
# `main.swift` is implicitly @MainActor under Swift 6, and the relay reads Claude's stdout on a
# Dispatch queue. The moment that handler touched a top-level binding, the runtime isolation check
# failed and the process died with SIGTRAP — so the tab opened, printed its header, and the relay
# was already gone when the first line arrived. Nothing was logged and nothing timed out. Only
# running the real binary against a real stream shows it, which is why it is checked here.
RELAY_DIR="$WORK/relay"
mkdir -p "$RELAY_DIR"
cat > "$RELAY_DIR/stub-claude" <<'STUB'
#!/bin/bash
echo '{"type":"system","subtype":"init","session_id":"stub"}'
while IFS= read -r line; do
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"PONG from the stub"}]}}'
  echo '{"type":"result","subtype":"success","is_error":false,"result":"PONG from the stub"}'
  break
done
STUB
chmod +x "$RELAY_DIR/stub-claude"
mkfifo -m 600 "$RELAY_DIR/in" "$RELAY_DIR/out"
cat "$RELAY_DIR/out" > "$RELAY_DIR/frames.log" &
RELAY_READER=$!
( sleep 0.4
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"ping"}]}}'
  sleep 6 ) > "$RELAY_DIR/in" &
RELAY_WRITER=$!
RELAY_UUID="$(/usr/bin/python3 -c 'import uuid;print(str(uuid.uuid4()).upper())')"
set +e
"$SESSION" --session-id "$RELAY_UUID" --cwd "$WORK" --claude "$RELAY_DIR/stub-claude" \
  --inbox "$RELAY_DIR/in" --outbox "$RELAY_DIR/out" > "$RELAY_DIR/tab.log" 2>&1
RELAY_STATUS=$?
set -e
kill "$RELAY_WRITER" "$RELAY_READER" 2>/dev/null || true

check "the relay exits cleanly rather than trapping (133 was SIGTRAP)" "0" "$RELAY_STATUS"
contains "the tab says which session it is" "$RELAY_UUID" "$(cat "$RELAY_DIR/tab.log")"
contains "and states plainly that typing is not enabled" "Typing here is not enabled" "$(cat "$RELAY_DIR/tab.log")"
contains "the reply is rendered for the person to read" "PONG from the stub" "$(cat "$RELAY_DIR/tab.log")"
missing "and the raw protocol is never shown in the tab" '"type":"assistant"' "$(cat "$RELAY_DIR/tab.log")"
contains "the raw frames go back to Warden verbatim" '"type":"assistant"' "$(cat "$RELAY_DIR/frames.log")"
check "every frame the client produced reached Warden" "3" "$(wc -l < "$RELAY_DIR/frames.log" | tr -d ' ')"

echo
echo "-----------------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
