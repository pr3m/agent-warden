#!/bin/bash
# Install Agent Warden's hooks into Claude Code.
#
# What this changes on your machine:
#   1. ~/.claude/settings.json  — adds hook entries pointing at this repo's aa-emit binary.
#                                 A timestamped backup is made first. Existing hooks are kept.
#   2. <data dir>/install-manifest.json — the exact commands we added, per settings file, so
#                                 uninstall.sh can take exactly those back out and nothing else.
#   3. Nothing else. No login item unless you pass --login-item.
#
# Usage:
#   ./install.sh                 build if needed, back up, wire hooks, offer to launch
#   ./install.sh --dry-run       show the resulting hooks block, change nothing
#   ./install.sh --settings PATH target a project settings file instead of the user one
#   ./install.sh --login-item    also start the app at login (opt-in, off by default)
#   ./install.sh --no-launch     wire the hooks but do not start the app now
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/AgentWarden.app"
APP_BINARY="$APP/Contents/MacOS/AgentWarden"
EMIT="$APP/Contents/MacOS/aa-emit"
STATUS="$APP/Contents/MacOS/aa-status"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/dev.agentwarden.plist"
LAUNCH_LABEL="dev.agentwarden"

SETTINGS="$HOME/.claude/settings.json"
DRY_RUN=""
LOGIN_ITEM=""
LAUNCH="yes"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    --settings) SETTINGS="$2"; shift 2 ;;
    --login-item) LOGIN_ITEM="yes"; shift ;;
    --no-launch) LAUNCH=""; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -x "$EMIT" ]; then
  echo "Building the app first…"
  "$ROOT/Scripts/build-app.sh" release
fi

echo "== Wiring Claude Code hooks =="
/usr/bin/python3 "$ROOT/Scripts/manage-hooks.py" install --settings "$SETTINGS" --emit-path "$EMIT" $DRY_RUN

if [ -n "$DRY_RUN" ]; then
  exit 0
fi

if [ -n "$LOGIN_ITEM" ]; then
  echo
  echo "== Installing the login item =="
  # Ownership is decided by parsing the plist, not by grepping for the label: a comment or an
  # unrelated agent that mentions us must not be overwritten.
  if ! /usr/bin/python3 "$ROOT/Scripts/launch-agent.py" write "$LAUNCH_AGENT" "$LAUNCH_LABEL" "$APP_BINARY"; then
    exit 1
  fi
  launchctl bootout "gui/$UID/$LAUNCH_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT"
  echo "login item    : $LAUNCH_AGENT"
fi

echo
echo "== Done =="
echo "Claude Code watches its settings file and reloads hooks by itself, so sessions that are"
echo "already running pick these up without being restarted. Nothing needs to be closed."
echo "Agent Warden also reads Claude Code's session registry, so sessions that were already"
echo "running appear straight away — listed as awaiting their first hook until one arrives."
echo
echo "Next:"
echo "  • Menu bar icon: ● with the number of sessions waiting; ◦ when nothing needs you."
echo "  • Click an alert once and macOS will ask to let Agent Warden control your terminal."
echo "    Allow it, or click-through falls back to the copy-resume button on the card."
echo "  • Query it without looking at the screen:  \"$STATUS\" --json"
echo "  • Remove everything with ./uninstall.sh"

if [ -n "$LAUNCH" ] && [ -z "$LOGIN_ITEM" ]; then
  echo
  read -r -p "Launch Agent Warden now? [y/N] " reply
  case "$reply" in
    [yY]*) open "$APP"; echo "launched." ;;
    *) echo "Not launched. Start it later with: open \"$APP\"" ;;
  esac
fi
