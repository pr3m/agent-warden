#!/bin/bash
# Install or remove the Agent Warden power helper.
#
# The helper runs as root, so every input it touches must be somewhere the installing
# user cannot write. A root daemon executing a user-writable binary is arbitrary root
# execution for anyone who can write that file — and this project's normal homes
# (build/, ~/Applications, ~/.local/bin) are all user-writable. Hence /Library.
#
# What this changes on your machine (install):
#   /Library/PrivilegedHelperTools/dev.agentwarden.powerd  — the daemon binary, root:wheel 755
#   /Library/LaunchDaemons/dev.agentwarden.powerd.plist     — the launchd job, root:wheel 644
#   /Library/Application Support/dev.agentwarden/           — root:wheel 700
#     allowed-uid                                           — the installing user's uid, root:wheel 600
#   /var/run/dev.agentwarden.powerd.sock                    — created by launchd, owned by the installing user
# uninstall reverses all of the above, releasing any sleep block first.
#
# Usage:  install-powerd.sh install <path-to-aa-powerd>
#         install-powerd.sh uninstall
set -euo pipefail

LABEL="dev.agentwarden.powerd"
HELPER="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT="/Library/Application Support/dev.agentwarden"
SOCKET="/var/run/$LABEL.sock"
TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/Resources/$LABEL.plist"

case "${1:-}" in
install)
  SRC="${2:?usage: install-powerd.sh install <path-to-aa-powerd>}"
  [ -x "$SRC" ] || { echo "not executable: $SRC" >&2; exit 1; }
  UID_NUM="$(id -u)"

  echo "Installing the power helper. This needs your password once."
  sudo mkdir -p /Library/PrivilegedHelperTools "$SUPPORT"
  sudo chown root:wheel /Library/PrivilegedHelperTools "$SUPPORT"
  sudo chmod 755 /Library/PrivilegedHelperTools
  sudo chmod 700 "$SUPPORT"

  # Atomic replace, then ownership, then load — never the other way round.
  sudo cp "$SRC" "$HELPER.new"
  sudo chown root:wheel "$HELPER.new"
  sudo chmod 755 "$HELPER.new"
  sudo mv -f "$HELPER.new" "$HELPER"

  printf '%s\n' "$UID_NUM" | sudo tee "$SUPPORT/allowed-uid" >/dev/null
  sudo chown root:wheel "$SUPPORT/allowed-uid"
  sudo chmod 600 "$SUPPORT/allowed-uid"

  sed "s/__UID__/$UID_NUM/" "$TEMPLATE" | sudo tee "$PLIST" >/dev/null
  sudo chown root:wheel "$PLIST"
  sudo chmod 644 "$PLIST"

  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo launchctl bootstrap system "$PLIST"
  echo "Installed. Socket: $SOCKET"
  echo
  echo "If roam ever leaves your Mac unable to sleep, the repair is:"
  echo "    sudo pmset -a disablesleep 0"
  ;;
uninstall)
  echo "Removing the power helper. This needs your password once."
  # Release before removing the thing that would have released it.
  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo pmset -a disablesleep 0 || true
  # Fixed constants only. Never a path read from install-manifest.json, which is
  # user-writable and would otherwise be a root-deletion primitive.
  sudo rm -f "$HELPER" "$PLIST" "$SUPPORT/allowed-uid" "$SUPPORT/held" "$SOCKET"
  sudo rmdir "$SUPPORT" 2>/dev/null || true
  if [ "$(pmset -g | awk '/SleepDisabled/ {print $2}')" != "0" ]; then
    echo "WARNING: SleepDisabled is still set. Run: sudo pmset -a disablesleep 0" >&2
  fi
  echo "Removed."
  ;;
*)
  echo "usage: install-powerd.sh {install <path>|uninstall}" >&2
  exit 64
  ;;
esac
