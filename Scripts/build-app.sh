#!/bin/bash
# Build Agent Warden.app plus the aa-emit hook binary, the aa-status query binary and the
# aa-bridge session bridge. The bridge is bundled, never launched: the app does not host it, and a
# host only ever runs with directories a person named.
#
# SwiftPM produces plain executables; this assembles them into a real .app bundle so macOS treats
# the app as an application (menu bar item, Automation permission prompts, floating panel).
#
# Output: build/AgentWarden.app  (displayed as "Agent Warden")
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${1:-release}"
# No space in the bundle filename: it ends up inside a shell command string in settings.json and
# in launchd plists, and every one of those is one more place to get quoting wrong. The name the
# user sees comes from CFBundleDisplayName.
APP="$ROOT/build/AgentWarden.app"
VERSION="$(sed -n 's/.*static let string = "\(.*\)"/\1/p' Sources/AgentAttentionCore/Version.swift | head -1)"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product AgentAttention
swift build -c "$CONFIG" --product aa-emit
swift build -c "$CONFIG" --product aa-status
swift build -c "$CONFIG" --product aa-bridge
swift build -c "$CONFIG" --product aa-session
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/AgentAttention" "$APP/Contents/MacOS/AgentWarden"
cp "$BIN/aa-emit" "$APP/Contents/MacOS/aa-emit"
cp "$BIN/aa-status" "$APP/Contents/MacOS/aa-status"
# Bundled so it ships with the app — and **not** started by it. The bridge host runs only when
# somebody runs it, with the directories they name; nothing here auto-starts a host or approves a
# directory on the user's behalf.
cp "$BIN/aa-bridge" "$APP/Contents/MacOS/aa-bridge"
cp "$BIN/aa-session" "$APP/Contents/MacOS/aa-session"

# plistlib rather than a heredoc: the bundle path is interpolated, and a path containing an
# ampersand would produce an invalid plist if pasted in raw.
/usr/bin/python3 - "$APP/Contents/Info.plist" "$VERSION" <<'PY'
import plistlib, sys
target, version = sys.argv[1], sys.argv[2]
plist = {
    "CFBundleName": "Agent Warden",
    "CFBundleDisplayName": "Agent Warden",
    "CFBundleIdentifier": "dev.agentwarden.app",
    "CFBundleExecutable": "AgentWarden",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": version,
    "CFBundleShortVersionString": version,
    "LSMinimumSystemVersion": "14.0",
    # Menu-bar only: no Dock icon, no main window.
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
    # Shown when macOS asks whether this app may control your terminal, which is how a click on an
    # alert lands on the right tab.
    "NSAppleEventsUsageDescription":
        "Agent Warden brings the terminal window of the Claude Code session that needs you to the front.",
}
with open(target, "wb") as handle:
    plistlib.dump(plist, handle)
PY

# Ad-hoc signature so macOS keeps a stable identity for TCC (Automation) grants across launches.
# This is not distribution signing; see BACKLOG.md.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
  && echo "Ad-hoc signed." \
  || echo "codesign unavailable — the app still runs, but macOS may re-ask for Automation access."

echo
echo "Built: $APP"
echo "  app         : $APP/Contents/MacOS/AgentWarden"
echo "  hook binary : $APP/Contents/MacOS/aa-emit"
echo "  status CLI  : $APP/Contents/MacOS/aa-status"
echo "  bridge CLI  : $APP/Contents/MacOS/aa-bridge  (never auto-started; needs explicit --approve)"
echo "  session relay: $APP/Contents/MacOS/aa-session  (runs inside a Ghostty tab; started only by aa-bridge)"
echo
# A build that stops at "it compiled" leaves two different facts — that it built, and that it is the
# thing running on your machine. Unless something is explicitly driving this script (the pipeline
# itself, or install.sh), a successful build carries on into the gates and installs.
if [ -z "${AGENT_WARDEN_NO_AUTO_INSTALL:-}" ]; then
  echo
  exec "$(dirname "$0")/release.sh" --already-built
fi

echo "Next: ./Scripts/release.sh   (gates, then installs and restarts Agent Warden)"
