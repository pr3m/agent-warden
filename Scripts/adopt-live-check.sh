#!/bin/bash
# Live acceptance for adopting a terminal session — opt-in, one disposable conversation, nothing else.
#
# What it does, and only this:
#   1. seeds a new, disposable conversation in a scratch project under build/qa/adopt-live, telling
#      it a random code word;
#   2. opens that conversation in an interactive Claude client on a private pty — the "session the
#      user started in a terminal". Nothing is ever typed into it;
#   3. records that client in a SANDBOXED Warden home (never the real one) and starts a sandboxed
#      bridge host whose only approved directory is the scratch project;
#   4. adopts it: prepare, a refused complete while the client runs, detach terminate, complete;
#   5. asks the resumed conversation for the code word through aa-mcp — the proof it is the same
#      conversation — then opens a second interactive client on it and checks a send is refused;
#   6. stops everything it started, and writes evidence to build/qa/adopt-live/evidence.
#
# Every process it signals is one it started. Claude Code writes its own transcript and registry
# entries for the disposable conversation under ~/.claude, as it does for any session.
#
#   AGENT_WARDEN_LIVE_ADOPT=1 ./Scripts/adopt-live-check.sh
set -uo pipefail
cd "$(dirname "$0")/.."

if [ "${AGENT_WARDEN_LIVE_ADOPT:-0}" != "1" ]; then
  echo "This starts real Claude Code clients. Re-run with AGENT_WARDEN_LIVE_ADOPT=1 to opt in."
  exit 0
fi

CONFIG="${ADOPT_CONFIG:-debug}"
MODEL="${ADOPT_MODEL:-haiku}"
TURN_TIMEOUT="${ADOPT_TURN_TIMEOUT:-180}"
swift build -c "$CONFIG" >/dev/null || { echo "build failed"; exit 1; }
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
BRIDGE="$BIN/aa-bridge"; MCP="$BIN/aa-mcp"; APP="$BIN/AgentAttention"
CLAUDE="${ADOPT_CLAUDE:-$HOME/.local/bin/claude}"
[ -x "$CLAUDE" ] || { echo "no Claude Code executable at $CLAUDE"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1"; }
contains() { case "$3" in *"$2"*) ok "$1";; *) bad "$1 (missing '$2')";; esac; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

LIVE="$PWD/build/qa/adopt-live"
rm -rf "$LIVE"
mkdir -p "$LIVE/project" "$LIVE/home" "$LIVE/evidence"
PROJECT="$(cd "$LIVE/project" && pwd -P)"
export AGENT_ATTENTION_HOME="$LIVE/home"          # the sandbox; the real Warden never hears of this
# Run as a person's terminal would, not as a child of whatever session launched this script.
unset CLAUDECODE CLAUDE_PID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT \
      CLAUDE_CODE_EXECPATH CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
SOCK="$LIVE/home/bridge.sock"
ID="$(/usr/bin/python3 -c 'import uuid;print(uuid.uuid4())')"
WORD="PELICAN-$(/usr/bin/python3 -c 'import secrets;print(secrets.token_hex(3).upper())')"
# No user settings for the clients this script starts by hand: no hooks, no plugins, no tools.
# `--mcp-config` takes a list, so it goes last and nothing positional may follow it.
QUIET=(--model "$MODEL" --setting-sources project --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}')

# Pids go to a file, not an array: helpers run in command substitutions, whose variables never
# reach this shell, and a holder left behind keeps the output pipe open for fifteen minutes.
PIDS="$LIVE/started.pids"
: > "$PIDS"
cleanup() {
  while read -r pid; do kill "$pid" 2>/dev/null; done < "$PIDS"
  [ -n "${HOST:-}" ] && kill -TERM "$HOST" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

registry_pids() { # live pids Claude Code's registry lists for a conversation
  /usr/bin/python3 - "$1" <<'PY'
import glob, json, os, sys
for path in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try:
        record = json.load(open(path))
    except Exception:
        continue
    if record.get("sessionId") == sys.argv[1]:
        try:
            os.kill(int(record["pid"]), 0)
            print(record["pid"], record.get("kind", "?"), record.get("entrypoint", "?"))
        except Exception:
            pass
PY
}

# A private pty for an interactive client, held by a tiny runner that only ever reads from it. It
# records the client's pid, copies what the client draws to a log, and exits when the client does.
cat > "$LIVE/pty-runner.py" <<'PY'
import fcntl, os, pty, select, struct, sys, termios
log, pidfile, argv = sys.argv[1], sys.argv[2], sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
open(pidfile, "w").write(str(pid))
with open(log, "ab") as out:
    while True:
        ready, _, _ = select.select([fd], [], [], 1.0)
        if fd in ready:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            out.write(data); out.flush()
        elif os.waitpid(pid, os.WNOHANG)[0]:
            break
PY

open_interactive() { # open_interactive <log>  → prints the claude pid
  local pidfile="$LIVE/pid-$RANDOM"
  ( cd "$PROJECT" && exec /usr/bin/python3 "$LIVE/pty-runner.py" "$1" "$pidfile" \
      "$CLAUDE" --resume "$ID" --settings "$HOOKED" "${QUIET[@]}" ) </dev/null >/dev/null 2>&1 &
  echo "$!" >> "$PIDS"
  for _ in $(seq 1 100); do [ -s "$pidfile" ] && break; sleep 0.1; done
  local child; child="$(cat "$pidfile" 2>/dev/null)"
  [ -n "$child" ] && echo "$child" >> "$PIDS"
  echo "$child"
}

# The interactive client reports itself through the real hook, into the sandbox — the same path a
# person's session takes, with no record written by hand.
HOOKED='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"'"$BIN"'/aa-emit --signal sessionStart"}]}]}}'

echo "== seed a disposable conversation =="
( cd "$PROJECT" && "$CLAUDE" "Remember this code word for later: $WORD. Reply with just OK." \
    -p --session-id "$ID" "${QUIET[@]}" ) > "$LIVE/evidence/seed.txt" 2>&1
TRANSCRIPT="$(ls ~/.claude/projects/*/"$ID".jsonl 2>/dev/null | head -1)"
if [ -z "$TRANSCRIPT" ]; then
  bad "no transcript for $ID — see $LIVE/evidence/seed.txt"
  exit 1
fi
ok "the conversation exists ($(wc -l < "$TRANSCRIPT" | tr -d ' ') records)"
LINES_BEFORE="$(wc -l < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')"

echo "== the session the user started in a terminal =="
ORIG="$(open_interactive "$LIVE/evidence/original-tty.log")"
if [ -z "$ORIG" ]; then bad "the interactive client did not start"; exit 1; fi
ok "an interactive client holds it (pid $ORIG)"
for _ in $(seq 1 150); do registry_pids "$ID" | grep -q "^$ORIG " && break; sleep 0.2; done
REG="$(registry_pids "$ID")"
printf '%s\n' "$REG" > "$LIVE/evidence/registry-with-original.txt"
contains "Claude Code's registry lists that client under the conversation" "$ORIG" "$REG"
for _ in $(seq 1 100); do [ -f "$LIVE/home/sessions/$ID.json" ] && break; sleep 0.1; done
[ -f "$LIVE/home/sessions/$ID.json" ] && ok "its own SessionStart hook reported it to the sandbox" \
  || bad "the client's hook never reported it"
mkdir -p "$LIVE/no-registry/sessions"
# One app cycle folds the hook into the queue. Discovery is pointed at an empty registry so the
# sandbox never lists anybody's real sessions.
AGENT_WARDEN_CLAUDE_HOME="$LIVE/no-registry" "$APP" --selftest > "$LIVE/evidence/selftest.txt" 2>&1
printf '{"approvedRoots":["%s"]}\n' "$PROJECT" > "$LIVE/home/bridge.json"

"$BRIDGE" serve --socket "$SOCK" --no-tools 2> "$LIVE/evidence/host.log" &
HOST=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done
contains "the sandboxed host lists the terminal session as observed" "$ID" "$("$BRIDGE" sessions --socket "$SOCK")"

echo "== adopt it =="
AUTH="live check: adopt the disposable session"
A1="$("$BRIDGE" adopt prepare --session "$ID" --request-id live-1 --authorize "$AUTH" --socket "$SOCK")"
printf '%s\n' "$A1" > "$LIVE/evidence/prepare.json"
contains "prepare pins it and waits for the terminal client" '"phase" : "awaitingDetach"' "$A1"
A2="$("$BRIDGE" adopt complete --session "$ID" --request-id live-1 --authorize "$AUTH" --socket "$SOCK")"
check "complete is refused while the terminal client runs (exit 3)" "3" "$?"
contains "because a writer still holds it" "writerConflict" "$A2"
A3="$("$BRIDGE" adopt prepare --session "$ID" --request-id live-1 --detach terminate --authorize "$AUTH" --socket "$SOCK")"
printf '%s\n' "$A3" > "$LIVE/evidence/terminate.json"
contains "detach terminate sees the idle client leave" '"phase" : "ready"' "$A3"
kill -0 "$ORIG" 2>/dev/null; check "the terminal client has exited" "1" "$?"
tail -c 2000 "$LIVE/evidence/original-tty.log" | LC_ALL=C tr -cd '\11\12\15\40-\176' > "$LIVE/evidence/original-tty-tail.txt"
/usr/bin/python3 -c 'import json,sys;[json.loads(l) for l in open(sys.argv[1]) if l.strip()]' "$TRANSCRIPT"
check "the transcript is intact after it left" "0" "$?"
A4="$("$BRIDGE" adopt complete --session "$ID" --request-id live-1 --model "$MODEL" --authorize "$AUTH" --socket "$SOCK")"
printf '%s\n' "$A4" > "$LIVE/evidence/complete.json"
contains "complete resumes it under Warden" '"phase" : "adopted"' "$A4"
contains "under the same conversation id" "\"sessionID\" : \"$ID\"" "$A4"

echo "== the same conversation, through MCP =="
MCP_OUT="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"warden_send_prompt","arguments":{"sessionId":"'"$ID"'","messageId":"live-m1","prompt":"What code word did I give you earlier? Reply with just the word.","waitSeconds":30,"authorization":{"confirmed":true,"statement":"live check: ask for the code word"}}}}' \
  | "$MCP" --socket "$SOCK")"
printf '%s\n' "$MCP_OUT" > "$LIVE/evidence/mcp-send.jsonl"
contains "the send is acknowledged by the resumed client" '"delivery":"acknowledged"' "$MCP_OUT"
for _ in $(seq 1 "$TURN_TIMEOUT"); do
  "$BRIDGE" status --session "$ID" --socket "$SOCK" | grep -q '"phase" : "completed"' && break
  sleep 1
done
EVENTS="$("$BRIDGE" events --session "$ID" --socket "$SOCK")"
printf '%s\n' "$EVENTS" > "$LIVE/evidence/events.json"
contains "the answer carries the code word from before the handoff" "$WORD" "$EVENTS"
registry_pids "$ID" > "$LIVE/evidence/registry-after-adoption.txt"

echo "== a second writer is refused =="
SECOND="$(open_interactive "$LIVE/evidence/second-tty.log")"
for _ in $(seq 1 150); do registry_pids "$ID" | grep -q "^$SECOND " && break; sleep 0.2; done
registry_pids "$ID" > "$LIVE/evidence/registry-with-second.txt"
S1="$("$BRIDGE" send --session "$ID" --message-id live-m2 --prompt "Reply with OK." --authorize "live check" --socket "$SOCK")"
printf '%s\n' "$S1" > "$LIVE/evidence/second-writer-send.json"
contains "a send is refused while another client holds the conversation" "writerConflict" "$S1"
kill "$SECOND" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$SECOND" 2>/dev/null || break; sleep 0.1; done

echo "== stop =="
"$BRIDGE" stop --session "$ID" --socket "$SOCK" >/dev/null
check "a stop without --authorize is refused (exit 3)" "3" "$?"
STOP="$("$BRIDGE" stop --session "$ID" --authorize "live check: done" --socket "$SOCK")"
contains "an authorised stop is accepted" '"ok" : true' "$STOP"
kill -TERM "$HOST"; wait "$HOST" 2>/dev/null
check "the host stops cleanly" "0" "$?"
HOST=""
cp "$LIVE/home/bridge-audit.jsonl" "$LIVE/evidence/" 2>/dev/null
LEFT="$(pgrep -f -- "--resume $ID" | wc -l | tr -d ' ')"
check "no client for this conversation is left running" "0" "$LEFT"
echo "  transcript: $TRANSCRIPT ($LINES_BEFORE → $(wc -l < "$TRANSCRIPT" | tr -d ' ') records)"

echo
printf 'passed: %d   failed: %d   evidence: %s\n' "$PASS" "$FAIL" "$LIVE/evidence"
[ "$FAIL" -eq 0 ]
