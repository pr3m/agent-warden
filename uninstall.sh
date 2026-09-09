#!/bin/bash
# Remove Agent Warden from Claude Code.
#
# Removes only the hook entries recorded as ours in the install manifest, matched exactly.
# Everything else in your settings file is copied through untouched, and a timestamped backup is
# written first. A hook of yours that merely mentions aa-emit is not ours and is left alone.
#
# Also restores statusLine.command to whatever it was before install.sh touched it (from
# install-manifest.json) and removes ~/.claude/bin/agent-warden-statusline.sh. Refuses, rather
# than guessing, if statusLine.command has since changed to something install.sh did not write.
#
# Also removes the power helper (needed for lid-closed roam) — asks for your password once,
# releases any sleep block it is holding, then deletes the root:wheel paths install.sh created:
# /Library/PrivilegedHelperTools/dev.agentwarden.powerd, /Library/LaunchDaemons/dev.agentwarden.
# powerd.plist, and /Library/Application Support/dev.agentwarden/. Skipped, like the login item,
# PATH links and the status line, when --settings names a non-default file.
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

DEFAULT_SETTINGS="$HOME/.claude/settings.json"
SETTINGS="$DEFAULT_SETTINGS"
DRY_RUN=""
PURGE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    --settings) SETTINGS="$2"; shift 2 ;;
    --purge) PURGE="yes"; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# Must run BEFORE "Removing Claude Code hooks" below. manage-hooks.py deletes
# install-manifest.json outright once its own "targets" section is empty (Scripts/manage-hooks.py
# is not ours to change — see Scripts/manage-statusline.py's manifest_is_empty() docstring), with
# no awareness of this script's own "statusLine" section in that same shared file. On a machine
# with exactly one hooks target — the common case, and the one this was caught against — removing
# hooks first empties "targets", deletes the whole manifest file, and leaves nothing for the
# statusline restore below to read: it then correctly refuses to guess rather than doing the wrong
# thing, but the user's real statusLine.command never comes back. Running statusline first pops
# our own entry (and, if nothing else remains, deletes the file itself) while "targets" is still
# whatever it already was; hooks' own cleanup then runs after and makes its usual correct decision
# about the manifest.
#
# Guarded and dry-run-handled like install.sh's own statusline block, not like the hooks call
# below: statusLine.command always resolves to one fixed real path
# (~/.claude/bin/agent-warden-statusline.sh) regardless of which --settings file was named, so
# touching it while --settings names a project or test file would still touch that one real path.
echo "== Removing the Claude Code status line =="
if [ "$SETTINGS" != "$DEFAULT_SETTINGS" ]; then
  echo "note: --settings names a file other than the user one, so the status line is left"
  echo "      alone. Run without --settings to remove it too."
elif [ -n "$DRY_RUN" ]; then
  # Captured, not swallowed, same reasoning as the --write branch below: under set -e, an
  # unguarded refusal here (the documented "statusLine.command has drifted" case) would abort
  # the rest of this preview outright instead of still showing what the remaining steps would do.
  if ! /usr/bin/python3 "$ROOT/Scripts/manage-statusline.py" uninstall --settings "$SETTINGS" --dry-run; then
    echo "WARNING: status line preview reported a failure — see output above (most likely the" >&2
    echo "         documented refusal when statusLine.command no longer matches Warden's" >&2
    echo "         wrapper). This preview cannot show a restoration for it; continuing to show" >&2
    echo "         what the rest of a real run would do." >&2
  fi
else
  # Captured, not swallowed — the same pattern the power helper uses below, and for the same
  # reason. do_uninstall in manage-statusline.py deliberately exits 1 rather than guess when
  # statusLine.command has drifted since install; under set -e (line 23), an unguarded call left
  # that exit code free to abort this entire script right here — skipping hooks removal, the
  # login item, the PATH links, and worst of all the power-helper teardown further down, which
  # releases a machine-wide sleep block held by a root daemon. Failing to restore a status line
  # is a nuisance; leaving that daemon and its sleep block behind because of an unrelated
  # statusline refusal is not, so this warns with exactly what is still wrong and how to finish
  # it by hand, and lets every step after it still run.
  if ! /usr/bin/python3 "$ROOT/Scripts/manage-statusline.py" uninstall --settings "$SETTINGS" --write; then
    echo "WARNING: status line uninstall reported a failure — see output above (most likely the" >&2
    echo "         documented refusal when statusLine.command no longer matches Warden's" >&2
    echo "         wrapper). Your original status line was NOT restored, and Warden's wrapper" >&2
    echo "         (~/.claude/bin/agent-warden-statusline.sh) is still installed and still" >&2
    echo "         referenced by statusLine.command in $SETTINGS. Point statusLine.command back" >&2
    echo "         at the wrapper and re-run:" >&2
    echo "             ./Scripts/manage-statusline.py uninstall --settings $SETTINGS --write" >&2
  fi
fi

echo
echo "== Removing Claude Code hooks =="
/usr/bin/python3 "$ROOT/Scripts/manage-hooks.py" uninstall --settings "$SETTINGS" $DRY_RUN

if [ -n "$DRY_RUN" ]; then
  exit 0
fi

# The login item and the PATH links belong to the *user-level* install, not to whichever settings
# file was named. A `--settings` pointed somewhere else is a project uninstall — or somebody testing
# this script — and taking the real login item with it is a side effect nobody asked for, and a
# silent one: the plist is simply gone and the app stops starting at login. Observed exactly once,
# which is why this guard exists.
if [ "$SETTINGS" != "$DEFAULT_SETTINGS" ]; then
  echo
  echo "note: --settings names a file other than the user one, so the login item and the PATH"
  echo "      links are left alone. Run without --settings to remove those too."
  echo
  echo "Done. Those hook entries are gone; nothing user-level was touched."
  exit 0
fi

# The power helper is a machine-level install, same as the login item and PATH links below:
# tied to the real user-level uninstall, not to whichever settings file was named above. It also
# releases any sleep block before removing the daemon that would otherwise have cleared it.
echo
echo "== Power helper (needed for lid-closed roam) =="
# Captured, not swallowed: a failed teardown of a root daemon that clears a sleep block is
# exactly the kind of failure that must not print "Done" and go quiet.
if ! bash "$ROOT/Scripts/install-powerd.sh" uninstall; then
  echo "WARNING: power helper uninstall reported a failure — see output above. The daemon," >&2
  echo "         its files, or the sleep block it was holding may still be present. Re-run" >&2
  echo "         ./Scripts/install-powerd.sh uninstall, or repair by hand:" >&2
  echo "             sudo pmset -a disablesleep 0" >&2
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
echo "== Removing the commands from your PATH =="
# Removed only where the link still points into an AgentWarden.app bundle. A real file, a
# directory, or somebody else's symlink that happens to share the name is not ours and is listed
# rather than deleted — the same rule the hooks and the login item are held to.
LINK_DIR="${LINK_DIR:-$HOME/.local/bin}"
removed=0
for name in aa-status aa-emit aa-bridge aa-session; do
  target="$LINK_DIR/$name"
  [ -L "$target" ] || continue
  existing="$(readlink "$target" || true)"
  case "$existing" in
    */AgentWarden.app/Contents/MacOS/*) rm -f "$target"; removed=$((removed + 1)) ;;
    *) echo "  left $target alone — it does not point into an Agent Warden bundle" ;;
  esac
done
echo "removed       : $removed command symlink(s) from $LINK_DIR"

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
