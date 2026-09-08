#!/bin/bash
# Live acceptance for the session bridge — opt-in, ONE disposable session, nothing else.
#
# What it does, and only this:
#   1. makes a scratch directory with its own CLAUDE.md marker;
#   2. starts an `aa-bridge` host whose only approved directory is that scratch, with tools and MCP
#      servers switched off for the client it will launch;
#   3. starts ONE new Claude Code session there, through the bridge;
#   4. sends two harmless prompts to that same session and checks the *correlated* results;
#   5. writes sanitised evidence, stops the session it started, and removes the scratch.
#
# It never touches an existing session, settings, hooks, or any repository, and sends no keystrokes
# anywhere. The only process it stops is the one it started.
#
#   AGENT_WARDEN_LIVE_BRIDGE=1 ./Scripts/bridge-live-check.sh
#
# Evidence is written to build/qa/bridge-live/ before cleanup.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ "${AGENT_WARDEN_LIVE_BRIDGE:-0}" != "1" ]; then
  echo "This starts a real Claude Code session. Re-run with AGENT_WARDEN_LIVE_BRIDGE=1 to opt in."
  exit 0
fi

CONFIG="${BRIDGE_CONFIG:-debug}"
MODEL="${BRIDGE_MODEL:-opus}"
TURN_TIMEOUT="${BRIDGE_TURN_TIMEOUT:-180}"
swift build -c "$CONFIG" >/dev/null || { echo "build failed"; exit 1; }
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
BRIDGE="$BIN/aa-bridge"
CLAUDE="${BRIDGE_CLAUDE:-$HOME/.local/bin/claude}"
[ -x "$CLAUDE" ] || { echo "no Claude Code executable at $CLAUDE"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1"; }
contains() { case "$3" in *"$2"*) ok "$1";; *) bad "$1 (missing '$2')";; esac; }

# Short private paths: a Unix socket path is limited to ~104 bytes, and a long temp path breaks bind.
SCRATCH="$(cd "$(mktemp -d "/tmp/wbl.XXXXXX")" && pwd -P)"
SOCKET="$SCRATCH/s"
EVIDENCE="build/qa/bridge-live"
mkdir -p "$EVIDENCE"

# Two different secrets, doing two different jobs:
#   MARKER lives in CLAUDE.md — proof the project's own instructions reached the client.
#   NONCE is given only in turn one — proof turn two is the same conversation.
MARKER="WARDEN-PROJECT-$(/usr/bin/python3 -c 'import secrets;print(secrets.token_hex(4).upper())')"
NONCE="NONCE-$(/usr/bin/python3 -c 'import secrets;print(secrets.token_hex(4).upper())')"
cat > "$SCRATCH/CLAUDE.md" <<EOF
# Scratch project for an Agent Warden bridge check

When asked for the project marker, answer with exactly: $MARKER
Answer in one short line. Do not read, write or run anything.
EOF

CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return
  CLEANED=1
  if [ -n "${SESSION:-}" ]; then
    timeout 10 "$BRIDGE" stop --session "$SESSION" --socket "$SOCKET" >/dev/null 2>&1
  fi
  if [ -n "${HOST_PID:-}" ]; then
    kill "$HOST_PID" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$HOST_PID" 2>/dev/null || break; /bin/sleep 0.2; done
    kill -0 "$HOST_PID" 2>/dev/null && kill -9 "$HOST_PID" 2>/dev/null
  fi
  cp "$SCRATCH/host.log" "$EVIDENCE/host.log" 2>/dev/null
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# One field out of a JSON response, by path. No grep over the whole blob: searching the document for
# the id we asked for would find the id we asked for, which proves nothing.
field() { /usr/bin/python3 -c '
import json,sys
data=json.load(sys.stdin)
node=data
for key in sys.argv[1:]:
    if node is None: break
    node=node.get(key) if isinstance(node,dict) else None
print("" if node is None else node)' "$@"; }

echo "== Bridge live check =="
echo "  scratch: $SCRATCH"
echo "  model:   $MODEL"

"$BRIDGE" serve --approve "$SCRATCH" --socket "$SOCKET" --claude "$CLAUDE" --no-tools \
  >"$SCRATCH/host.log" 2>&1 &
HOST_PID=$!
for _ in $(seq 1 50); do [ -S "$SOCKET" ] && break; /bin/sleep 0.1; done
if [ ! -S "$SOCKET" ]; then bad "the host never listened"; sed -n '1,20p' "$SCRATCH/host.log"; exit 1; fi
ok "the host is listening on its own socket"
[ "$(stat -f '%OLp' "$SOCKET")" = "600" ] && ok "and the socket is private to this user" || bad "socket is not 0600"

REFUSED="$(timeout 20 "$BRIDGE" start --cwd "$HOME" --request-id refuse-1 --socket "$SOCKET")"
contains "an unapproved directory is refused" '"directoryNotApproved"' "$REFUSED"

START="$(timeout 60 "$BRIDGE" start --cwd "$SCRATCH" --request-id live-1 --model "$MODEL" --socket "$SOCKET")"
SESSION="$(printf '%s' "$START" | field session sessionID)"
if [ -z "$SESSION" ]; then bad "no session was started"; printf '%s\n' "$START"; exit 1; fi
ok "a session was started"
[ "$(printf '%s' "$START" | field session phase)" = "accepted" ] \
  && ok "and it begins as accepted, not acknowledged" || bad "unexpected starting phase"

# --- Turn one ------------------------------------------------------------------------------------
timeout 20 "$BRIDGE" send --session "$SESSION" --message-id turn-1 --socket "$SOCKET" \
  --prompt "Reply in one line with the project marker from CLAUDE.md, then on a second line repeat exactly: $NONCE" \
  >/dev/null || { bad "the first prompt was not accepted"; exit 1; }

DEADLINE=$(( $(date +%s) + TURN_TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATE="$(timeout 20 "$BRIDGE" status --session "$SESSION" --socket "$SOCKET")"
  PHASE="$(printf '%s' "$STATE" | field session phase)"
  case "$PHASE" in completed|failed|uncertain|stopped) break;; esac
  /bin/sleep 2
done
printf '%s\n' "$STATE" > "$EVIDENCE/turn-1-state.json"

# Identity: the id the *client itself* reported, compared with the one we started.
REPORTED="$(printf '%s' "$STATE" | field session clientReportedSessionID)"
[ -n "$REPORTED" ] && [ "$REPORTED" = "$SESSION" ] \
  && ok "the client reports the very session this host started" \
  || bad "clientReportedSessionID was '$REPORTED', expected '$SESSION'"

ACK="$(printf '%s' "$STATE" | /usr/bin/python3 -c '
import json,sys
messages=json.load(sys.stdin)["session"]["messages"]
turn=[m for m in messages if m["messageID"]=="turn-1"]
print(turn[0].get("acknowledgedAt","") if turn else "")')"
[ -n "$ACK" ] && ok "the client acknowledged turn one by echoing our own message back" \
              || bad "turn one was never acknowledged"
[ "$PHASE" = "completed" ] && ok "and turn one completed" || bad "turn one ended as '$PHASE'"

# The result *correlated to turn one*, not any event that happens to contain the marker.
RESULT1="$(timeout 20 "$BRIDGE" events --session "$SESSION" --socket "$SOCKET" | /usr/bin/python3 -c '
import json,sys
events=json.load(sys.stdin).get("events") or []
print("\n".join(e.get("text") or "" for e in events
                if e.get("kind")=="result" and e.get("messageID")=="turn-1"))')"
printf '%s\n' "$RESULT1" > "$EVIDENCE/turn-1-result.txt"
contains "the project's own CLAUDE.md reached the session" "$MARKER" "$RESULT1"

# --- Turn two ------------------------------------------------------------------------------------
timeout 20 "$BRIDGE" send --session "$SESSION" --message-id turn-2 --socket "$SOCKET" \
  --prompt "In one short line: repeat the nonce I gave you a moment ago." >/dev/null \
  || { bad "the second prompt was not accepted"; exit 1; }

DEADLINE=$(( $(date +%s) + TURN_TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATE2="$(timeout 20 "$BRIDGE" status --session "$SESSION" --socket "$SOCKET")"
  DONE2="$(printf '%s' "$STATE2" | /usr/bin/python3 -c '
import json,sys
messages=json.load(sys.stdin)["session"]["messages"]
turn=[m for m in messages if m["messageID"]=="turn-2"]
print("yes" if turn and turn[0].get("completedAt") else "")')"
  [ -n "$DONE2" ] && break
  /bin/sleep 2
done
printf '%s\n' "$STATE2" > "$EVIDENCE/turn-2-state.json"
[ -n "$DONE2" ] && ok "turn two completed in the same session" || bad "turn two did not complete"

# Continuity: only the result correlated to turn two counts. The nonce is nowhere in CLAUDE.md, so
# repeating it can only come from remembering turn one.
RESULT2="$(timeout 20 "$BRIDGE" events --session "$SESSION" --socket "$SOCKET" | /usr/bin/python3 -c '
import json,sys
events=json.load(sys.stdin).get("events") or []
print("\n".join(e.get("text") or "" for e in events
                if e.get("kind")=="result" and e.get("messageID")=="turn-2"))')"
printf '%s\n' "$RESULT2" > "$EVIDENCE/turn-2-result.txt"
contains "turn two remembered turn one — one continuous conversation" "$NONCE" "$RESULT2"

# --- Refusals, against the live host --------------------------------------------------------------
DUP="$(timeout 20 "$BRIDGE" send --session "$SESSION" --message-id turn-2 --socket "$SOCKET" \
  --prompt "In one short line: repeat the nonce I gave you a moment ago.")"
contains "a repeated message id is accepted without resending" '"ok" : true' "$DUP"
CONFLICT="$(timeout 20 "$BRIDGE" send --session "$SESSION" --message-id turn-2 --prompt "something else" --socket "$SOCKET")"
contains "a conflicting message id is refused" '"idempotencyConflict"' "$CONFLICT"
FOREIGN="$(timeout 20 "$BRIDGE" send --session "11111111-2222-3333-4444-555555555555" \
  --message-id x --prompt hi --socket "$SOCKET")"
contains "a session this host did not start is refused" '"notOwned"' "$FOREIGN"

# A stop is a *request* first: the answer says `stopping` while the client is still up, and only
# the client's own exit turns that into `stopped`. Both are accepted here; what is not accepted is
# the host claiming an exit it has not seen.
STOPPED="$(timeout 20 "$BRIDGE" stop --session "$SESSION" --socket "$SOCKET")"
STOP_PHASE="$(printf '%s' "$STOPPED" | field session phase)"
case "$STOP_PHASE" in
  stopping|stopped) ok "the owned session is $STOP_PHASE" ;;
  *) bad "stop answered with phase '$STOP_PHASE'" ;;
esac

# And it does become `stopped` once the process has actually gone.
DEADLINE=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STOP_PHASE="$(timeout 20 "$BRIDGE" status --session "$SESSION" --socket "$SOCKET" | field session phase)"
  [ "$STOP_PHASE" = "stopped" ] && break
  /bin/sleep 1
done
[ "$STOP_PHASE" = "stopped" ] && ok "and the client's exit was actually observed" \
                             || bad "the session never confirmed its exit (phase '$STOP_PHASE')"
SESSION=""

# Sanitised evidence: states, correlated results, and the two secrets replaced by their names.
/usr/bin/python3 - "$EVIDENCE" "$MARKER" "$NONCE" <<'PY'
import pathlib, sys
folder, marker, nonce = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
for path in folder.glob('*'):
    if path.is_file():
        text = path.read_text(errors='replace')
        path.write_text(text.replace(marker, '<PROJECT-MARKER>').replace(nonce, '<TURN-ONE-NONCE>'))
PY
echo "  evidence: $EVIDENCE (secrets replaced by their names)"

echo
echo "-----------------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
