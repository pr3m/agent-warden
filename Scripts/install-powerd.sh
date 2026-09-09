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
  [ -f "$TEMPLATE" ] || { echo "missing plist template: $TEMPLATE" >&2; exit 1; }
  UID_NUM="$(id -u)"

  echo "Installing the power helper. This needs your password once."
  # /Library/PrivilegedHelperTools ships as a shared Apple directory (mode 1755, sticky bit
  # set) and, on many Macs, already holds other vendors' privileged helpers. Created only
  # when absent, with the mode baked into the mkdir itself — never chmod'd afterwards — so
  # an existing directory's sticky bit is never silently downgraded to 0755.
  #
  # When it already exists it is VERIFIED rather than corrected. The security of everything
  # below rests on this directory: a root daemon whose binary sits somewhere the installing
  # user can write is arbitrary root execution for anyone who can write that file, and the
  # 0755-mode helper we drop in is only as safe as the directory holding it. But a directory
  # this script did not create is not this script's to re-permission — silently chmod'ing a
  # shared Apple path (or one another vendor's installer set up) is its own way to break a
  # machine. So: refuse, say exactly what is wrong, and let a human decide. It is
  # `root:wheel drwxr-xr-t` on the machine this was written on, so this is a guard against a
  # tampered or oddly-restored system, not a live exposure.
  if [ ! -d /Library/PrivilegedHelperTools ]; then
    sudo mkdir -p -m 755 /Library/PrivilegedHelperTools
    sudo chown root:wheel /Library/PrivilegedHelperTools
  else
    HELPER_DIR_OWNER="$(stat -f '%u' /Library/PrivilegedHelperTools)"
    # Symbolic (`drwxr-xr-t`), not octal. `stat -f '%OLp'` drops leading zeros — mode 0020 comes
    # back as "20" — so digit positions in it are not fixed and a pattern written against three
    # digits silently misses exactly the group-writable case this is here to catch. The symbolic
    # form is always ten characters: 6 is the group write bit, 9 is the other write bit.
    HELPER_DIR_MODE="$(stat -f '%Sp' /Library/PrivilegedHelperTools)"
    if [ "$HELPER_DIR_OWNER" != "0" ]; then
      echo "refusing to install: /Library/PrivilegedHelperTools is owned by uid $HELPER_DIR_OWNER, not root." >&2
      echo "A root daemon installed into a directory somebody else owns is a root-execution hole." >&2
      echo "Inspect it (ls -ld /Library/PrivilegedHelperTools) and repair it deliberately:" >&2
      echo "    sudo chown root:wheel /Library/PrivilegedHelperTools" >&2
      exit 1
    fi
    # A symlink first, because `[ -d ]` above follows one and everything after this reads the
    # LINK's owner and mode, not the target's. A root-owned symlink pointing at a user-writable
    # directory would otherwise sail through both checks and put the helper exactly where it
    # must not go. `%Sp`'s first character is the type; anything but a real directory is refused.
    case "$HELPER_DIR_MODE" in
      d*) ;;
      *)
        echo "refusing to install: /Library/PrivilegedHelperTools is not a directory ($HELPER_DIR_MODE)." >&2
        echo "A symlink here would put a root daemon wherever it points. Inspect it:" >&2
        echo "    ls -ld /Library/PrivilegedHelperTools" >&2
        exit 1 ;;
    esac
    # Group- or world-writable is the same hole by another route: anyone in that set can
    # replace the helper binary this script is about to install.
    case "$HELPER_DIR_MODE" in
      ?????w????) GROUP_WRITABLE="yes" ;;
      *)          GROUP_WRITABLE="" ;;
    esac
    case "$HELPER_DIR_MODE" in
      ????????w?) WORLD_WRITABLE="yes" ;;
      *)          WORLD_WRITABLE="" ;;
    esac
    if [ -n "$WORLD_WRITABLE" ] || [ -n "$GROUP_WRITABLE" ]; then
      echo "refusing to install: /Library/PrivilegedHelperTools is $HELPER_DIR_MODE, which is" >&2
      echo "writable by ${GROUP_WRITABLE:+its group}${GROUP_WRITABLE:+${WORLD_WRITABLE:+ and }}${WORLD_WRITABLE:+everyone}." >&2
      echo "Anyone who can write that directory can replace the root helper installed into it." >&2
      echo "Inspect it (ls -ld /Library/PrivilegedHelperTools) and repair it deliberately:" >&2
      echo "    sudo chmod go-w /Library/PrivilegedHelperTools" >&2
      exit 1
    fi
  fi
  sudo mkdir -p "$SUPPORT"
  sudo chown root:wheel "$SUPPORT"
  sudo chmod 700 "$SUPPORT"

  # Atomic replace, then ownership, then load — never the other way round.
  sudo cp "$SRC" "$HELPER.new"
  sudo chown root:wheel "$HELPER.new"
  sudo chmod 755 "$HELPER.new"
  sudo mv -f "$HELPER.new" "$HELPER"

  printf '%s\n' "$UID_NUM" | sudo tee "$SUPPORT/allowed-uid" >/dev/null
  sudo chown root:wheel "$SUPPORT/allowed-uid"
  sudo chmod 600 "$SUPPORT/allowed-uid"

  # Rendered and checked in full before root ever sees it. `launchctl bootstrap` on an
  # invalid plist would leave the root binary installed with no working daemon behind it,
  # so nothing is written to /Library/LaunchDaemons until the render passes `plutil -lint`
  # and the two strings that are a contract with the daemon binary — Program and
  # SockPathName — are confirmed to say exactly what this script itself just installed.
  RENDERED="$(mktemp)"
  trap 'rm -f "$RENDERED"' EXIT
  sed "s/__UID__/$UID_NUM/" "$TEMPLATE" > "$RENDERED"
  plutil -lint "$RENDERED" >/dev/null || { echo "rendered plist failed plutil -lint: $RENDERED" >&2; exit 1; }
  RENDERED_PROGRAM="$(plutil -extract Program raw "$RENDERED")"
  RENDERED_SOCKET="$(plutil -extract Sockets.PowerdSocket.SockPathName raw "$RENDERED")"
  [ "$RENDERED_PROGRAM" = "$HELPER" ] || { echo "rendered plist Program ($RENDERED_PROGRAM) != $HELPER" >&2; exit 1; }
  [ "$RENDERED_SOCKET" = "$SOCKET" ] || { echo "rendered plist SockPathName ($RENDERED_SOCKET) != $SOCKET" >&2; exit 1; }

  sudo cp "$RENDERED" "$PLIST"
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
  # Runs no matter how this branch ends — clean completion, a failed sudo call under
  # set -e, or a declined password prompt — so the one warning built to catch a stranded
  # sleep block is never skipped in exactly the case it exists to catch.
  warn_if_sleep_disabled() {
    local state
    state="$(pmset -g | awk '/SleepDisabled/ {print $2}')"
    if [ "$state" != "0" ]; then
      echo "WARNING: SleepDisabled is still set. Run: sudo pmset -a disablesleep 0" >&2
    fi
  }
  trap warn_if_sleep_disabled EXIT

  # Release before removing the thing that would have released it.
  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo pmset -a disablesleep 0 || true
  # Fixed constants only. Never a path read from install-manifest.json, which is
  # user-writable and would otherwise be a root-deletion primitive.
  sudo rm -f "$HELPER" "$PLIST" "$SUPPORT/allowed-uid" "$SUPPORT/held" "$SOCKET"
  sudo rmdir "$SUPPORT" 2>/dev/null || true
  echo "Removed."
  ;;
*)
  echo "usage: install-powerd.sh {install <path>|uninstall}" >&2
  exit 64
  ;;
esac
