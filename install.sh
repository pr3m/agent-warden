#!/bin/bash
# Install Agent Warden's hooks into Claude Code.
#
# What this changes on your machine:
#   1. ~/.claude/settings.json  — adds hook entries pointing at this repo's aa-emit binary.
#                                 A timestamped backup is made first. Existing hooks are kept.
#   2. <data dir>/install-manifest.json — the exact commands we added, per settings file, so
#                                 uninstall.sh can take exactly those back out and nothing else.
#   3. ~/.local/bin/{aa-status,aa-emit,aa-bridge,aa-session,aa-roam} — symlinks, so the commands this
#                                 project documents can actually be typed. Only ever created where
#                                 nothing else is in the way; see --no-path to skip entirely.
#   4. ~/.claude/bin/agent-warden-statusline.sh and statusLine.command in ~/.claude/settings.json —
#                                 takes over the 🎒 roam indicator segment of your status line. If a
#                                 claude-code-roam wrapper is already installed, every other segment
#                                 it chains (your own status line, any hand-added block) is carried
#                                 over verbatim; only the roam-plugin's own indicator line is
#                                 replaced. The resulting wrapper is PRINTED AND CONFIRMED before
#                                 anything is written — this is not a silent migration. A timestamped
#                                 settings.json backup is made first, and the previous statusLine is
#                                 recorded so uninstall.sh restores it exactly.
#                                 Skipped when --settings names a non-default file — see below.
#   5. The power helper (needed for lid-closed roam) — asks for your password once, then writes,
#                                 all root:wheel and outside every user-writable path:
#                                   /Library/PrivilegedHelperTools/dev.agentwarden.powerd
#                                   /Library/LaunchDaemons/dev.agentwarden.powerd.plist  (loaded)
#                                   /Library/Application Support/dev.agentwarden/  (+ allowed-uid)
#                                 Skipped when --settings names a non-default file — see below.
#                                 Removed by ./uninstall.sh, releasing any sleep block first.
#   6. Nothing else. No login item unless you pass --login-item.
#
# Usage:
#   ./install.sh                 build if needed, back up, wire hooks, link the CLI, offer to launch
#   ./install.sh --dry-run       show the resulting hooks block, change nothing
#   ./install.sh --settings PATH target a project settings file instead of the user one — also
#                                 skips the status line and the power helper, since each of those
#                                 touches ONE fixed real path whichever settings file is named.
#                                 The login item (--login-item) and the PATH links are NOT skipped:
#                                 they are opt-in or idempotent and name no settings file at all.
#                                 (uninstall.sh does skip those two under --settings, because there
#                                 removing them is destructive and here creating them is not.)
#   ./install.sh --login-item    also start the app at login (opt-in, off by default)
#   ./install.sh --no-launch     wire the hooks but do not start the app now
#   ./install.sh --link-dir DIR  put the command symlinks somewhere else (default ~/.local/bin)
#   ./install.sh --no-path       do not put anything on PATH
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/AgentWarden.app"
APP_BINARY="$APP/Contents/MacOS/AgentWarden"
EMIT="$APP/Contents/MacOS/aa-emit"
STATUS="$APP/Contents/MacOS/aa-status"
ROAM_BIN="$APP/Contents/MacOS/aa-roam"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/dev.agentwarden.plist"
LAUNCH_LABEL="dev.agentwarden"
POWERD_LABEL="dev.agentwarden.powerd"

DEFAULT_SETTINGS="$HOME/.claude/settings.json"
SETTINGS="$DEFAULT_SETTINGS"
DRY_RUN=""
LOGIN_ITEM=""
LAUNCH="yes"
LINK_DIR="$HOME/.local/bin"
LINK_PATH="yes"
# The commands this project documents. `AgentWarden` itself is deliberately not linked: it is an
# app you open, not a command you type, and a bare `AgentWarden` on PATH would be a surprise.
LINK_NAMES="aa-status aa-emit aa-bridge aa-session aa-roam"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    --settings) SETTINGS="$2"; shift 2 ;;
    --login-item) LOGIN_ITEM="yes"; shift ;;
    --no-launch) LAUNCH=""; shift ;;
    --link-dir) LINK_DIR="$2"; shift 2 ;;
    --no-path) LINK_PATH=""; shift ;;
    -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -x "$EMIT" ] || [ ! -x "$APP/Contents/MacOS/aa-powerd" ] || [ ! -x "$ROAM_BIN" ]; then
  echo "Building the app first…"
  AGENT_WARDEN_NO_AUTO_INSTALL=1 "$ROOT/Scripts/build-app.sh" release
fi

echo "== Wiring Claude Code hooks =="
/usr/bin/python3 "$ROOT/Scripts/manage-hooks.py" install --settings "$SETTINGS" --emit-path "$EMIT" $DRY_RUN

echo
echo "== Claude Code status line =="
# statusLine.command in a settings file is a real, project-scoped setting (like hooks above) --
# but the file this writes it to point at, ~/.claude/bin/agent-warden-statusline.sh, is not: it is
# one fixed real-filesystem path, same for every settings file. Migrating it while --settings names
# a project or test file would still touch that one real path, which is not what a project-scoped
# --settings run is asking for -- so this is guarded exactly like the power helper below, not like
# the hooks step above.
if [ "$SETTINGS" != "$DEFAULT_SETTINGS" ]; then
  echo "note: --settings names a file other than the user one, so the status line is left"
  echo "      alone. Run without --settings to migrate it too."
elif [ -n "$DRY_RUN" ]; then
  /usr/bin/python3 "$ROOT/Scripts/manage-statusline.py" install --settings "$SETTINGS" --roam-bin "$ROAM_BIN" --dry-run
else
  # Preview, then ask. This edits a file the user hand-tuned -- on the machine this was written
  # against, one that chains their own status line AND a hand-added segment with no other copy
  # anywhere -- so the design says in as many words: "Show the resulting wrapper and ask before
  # writing. This edits a file the user hand-tuned; it is not a silent migration."
  #
  # manage-statusline.py already defaults to preview and requires --write; this was the one caller
  # that reached straight past that guard to --write. The preview below is the script's own dry
  # run, so what is shown is exactly what --write then produces.
  echo "This is the wrapper that would be written to ~/.claude/bin/agent-warden-statusline.sh:"
  echo
  /usr/bin/python3 "$ROOT/Scripts/manage-statusline.py" install --settings "$SETTINGS" --roam-bin "$ROAM_BIN" --dry-run
  echo
  if [ -t 0 ]; then
    read -r -p "Migrate your status line to this wrapper? [y/N] " statusline_reply
  else
    # No terminal to ask at (piped install, CI). Skipping is the safe direction: the rest of the
    # install still works, and roam's badge is the one thing lost until this is run by hand.
    statusline_reply="n"
    echo "note: no terminal to confirm at, so the status line was left alone."
  fi
  case "$statusline_reply" in
    [yY]*)
      /usr/bin/python3 "$ROOT/Scripts/manage-statusline.py" install --settings "$SETTINGS" --roam-bin "$ROAM_BIN" --write ;;
    *)
      echo "status line   : left alone. Apply it later with:"
      echo "                  /usr/bin/python3 $ROOT/Scripts/manage-statusline.py install \\"
      echo "                      --settings \"$SETTINGS\" --roam-bin \"$ROAM_BIN\" --write" ;;
  esac
fi

echo
echo "== Power helper (needed for lid-closed roam) =="
# Machine-level, like the login item and PATH links below: not tied to whichever settings file
# was named above. Mirrors uninstall.sh's guard so a project-scoped --settings can never install
# a root daemon that the matching uninstall would then refuse to remove.
if [ "$SETTINGS" != "$DEFAULT_SETTINGS" ]; then
  echo "note: --settings names a file other than the user one, so the power helper is left"
  echo "      alone. Run without --settings to install it too."
elif [ -n "$DRY_RUN" ]; then
  echo "would install $POWERD_LABEL from $APP/Contents/MacOS/aa-powerd"
else
  bash "$ROOT/Scripts/install-powerd.sh" install "$APP/Contents/MacOS/aa-powerd"
fi

if [ -n "$DRY_RUN" ]; then
  exit 0
fi

if [ -n "$LINK_PATH" ]; then
  echo
  echo "== Putting the commands on your PATH =="
  # Ownership is read from the link itself: a symlink is ours only if it resolves into an
  # AgentWarden.app bundle. Nothing is decided by the file's name — a real file, a directory, or
  # somebody else's symlink that happens to be called aa-status is left exactly where it is and
  # reported, because a tool that quietly replaces what it finds is not installable twice.
  mkdir -p "$LINK_DIR"
  linked=0
  refused=0
  for name in $LINK_NAMES; do
    source_binary="$APP/Contents/MacOS/$name"
    target="$LINK_DIR/$name"
    if [ ! -x "$source_binary" ]; then
      echo "  skipped $name — not in the app bundle"
      continue
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
      if [ -L "$target" ]; then
        existing="$(readlink "$target" || true)"
        case "$existing" in
          */AgentWarden.app/Contents/MacOS/*) ln -sfn "$source_binary" "$target"; linked=$((linked + 1)); continue ;;
        esac
      fi
      echo "  refused $target — already exists and is not one of ours. Left untouched."
      refused=$((refused + 1))
      continue
    fi
    ln -s "$source_binary" "$target"
    linked=$((linked + 1))
  done
  echo "linked        : $linked command(s) into $LINK_DIR"
  if [ "$refused" -gt 0 ]; then
    echo "refused       : $refused (see above; use --link-dir to choose elsewhere)"
  fi

  # Being on disk is not the same as being reachable. Say which it is, rather than leaving the
  # user to discover "command not found" later.
  case ":$PATH:" in
    *":$LINK_DIR:"*)
      echo "PATH          : $LINK_DIR is already on your PATH — \`aa-status\` works in a new shell" ;;
    *)
      echo "PATH          : $LINK_DIR is NOT on your PATH yet. Add this line to your shell profile:"
      echo "                  export PATH=\"$LINK_DIR:\$PATH\"" ;;
  esac
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
if [ -n "$LINK_PATH" ]; then
  echo "  • Query it without looking at the screen:  aa-status --json"
else
  echo "  • Query it without looking at the screen:  \"$STATUS\" --json"
fi
echo "  • Remove everything with ./uninstall.sh"

if [ -n "$LAUNCH" ] && [ -z "$LOGIN_ITEM" ]; then
  echo
  read -r -p "Launch Agent Warden now? [y/N] " reply
  case "$reply" in
    [yY]*) open "$APP"; echo "launched." ;;
    *) echo "Not launched. Start it later with: open \"$APP\"" ;;
  esac
fi
