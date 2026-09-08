#!/bin/bash
# Remove Agent Warden from Claude Code.
#
# Removes only the hook entries recorded as ours in the install manifest, matched exactly.
# Everything else in your settings file is copied through untouched, and a timestamped backup is
# written first. A hook of yours that merely mentions aa-emit is not ours and is left alone.
#
# Usage:
#   ./uninstall.sh                 remove hooks, stop the app, remove our login item if present
#   ./uninstall.sh --dry-run       show what would be removed, change nothing
#   ./uninstall.sh --settings PATH target a project settings file instead of the user one
#   ./uninstall.sh --purge         also delete the local data directory (queue, config, log)
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP_BINARY="$ROOT/build/AgentWarden.app/Contents/MacOS/AgentWarden"
DATA_DIR="${AGENT_ATTENTION_HOME:-$HOME/Library/Application Support/AgentAttention}"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/dev.agentwarden.plist"
LAUNCH_LABEL="dev.agentwarden"

SETTINGS="$HOME/.claude/settings.json"
DRY_RUN=""
PURGE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    --settings) SETTINGS="$2"; shift 2 ;;
    --purge) PURGE="yes"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "== Removing Claude Code hooks =="
/usr/bin/python3 "$ROOT/Scripts/manage-hooks.py" uninstall --settings "$SETTINGS" $DRY_RUN

if [ -n "$DRY_RUN" ]; then
  exit 0
fi

OWNERSHIP="$(/usr/bin/python3 "$ROOT/Scripts/launch-agent.py" check "$LAUNCH_AGENT" "$LAUNCH_LABEL" "$APP_BINARY")"
if [ "$OWNERSHIP" = "ours" ]; then
  echo
  echo "== Removing the login item =="
  launchctl bootout "gui/$UID/$LAUNCH_LABEL" 2>/dev/null || true
  /usr/bin/python3 "$ROOT/Scripts/launch-agent.py" remove "$LAUNCH_AGENT" "$LAUNCH_LABEL" "$APP_BINARY"
elif [ "$OWNERSHIP" = "foreign" ]; then
  echo
  echo "note: $LAUNCH_AGENT exists but is not ours — left untouched."
fi

echo
echo "== Stopping this copy of the app =="
# Matched on the full argument vector, not a pattern: `pkill -f AgentWarden` would also kill a
# second checkout, someone else's build, or an editor that happens to have the name on its
# command line.
/usr/bin/python3 - "$APP_BINARY" <<'PY'
import os, signal, subprocess, sys
target = sys.argv[1]
listing = subprocess.run(["/bin/ps", "-axo", "pid=,args="], capture_output=True, text=True).stdout
stopped = 0
for line in listing.splitlines():
    pid, _, args = line.strip().partition(" ")
    if args.strip() != target:
        continue
    try:
        os.kill(int(pid), signal.SIGTERM)
        stopped += 1
    except (ValueError, ProcessLookupError, PermissionError):
        pass
print(f"stopped {stopped} process(es) at {target}" if stopped else "not running")
PY

if [ -n "$PURGE" ]; then
  echo
  echo "== Deleting local data =="
  echo "This removes the attention queue, config and log at:"
  echo "  $DATA_DIR"
  read -r -p "Delete it? [y/N] " reply
  case "$reply" in
    [yY]*) rm -rf "$DATA_DIR"; echo "deleted." ;;
    *) echo "kept." ;;
  esac
else
  echo
  echo "Local data kept at: $DATA_DIR   (delete with ./uninstall.sh --purge)"
fi

echo
echo "Done. Claude Code sessions started from now on will no longer report to Agent Warden."
