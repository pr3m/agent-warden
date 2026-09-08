#!/bin/bash
# The whole pipeline: build it, prove it, install it.
#
# One command, so that "it builds" and "it is on your machine and working" stop being two different
# facts. Nothing reaches the running app that has not passed every gate first — the point of a local
# pipeline is not speed, it is that an unverified binary cannot quietly become the installed one.
#
#   ./Scripts/release.sh              build, run every gate, install, restart
#   ./Scripts/release.sh --no-install build and gate only; leave the running app alone
#   ./Scripts/release.sh --dry-run    build, gate, verify the bundle, install nothing
#
# Gates, in the order they fail fastest:
#   1. unit and integration tests   2. smoke test against the real binaries and installer
#   3. UI check on the bubble and panel
#
# Deliberately NOT a gate: the visible-Ghostty session. It opens a real tab on a real desktop, so it
# stays a thing a person runs and watches, not something a build does behind your back.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

INSTALL="yes"
DRY_RUN=""
ALREADY_BUILT=""
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --no-install) INSTALL=""; shift ;;
    --already-built) ALREADY_BUILT="yes"; shift ;;
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    --install-dir|--link-dir) EXTRA+=("$1" "$2"); shift 2 ;;
    --no-path|--no-restart) EXTRA+=("$1"); shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

started=$(date +%s)

if [ -n "$ALREADY_BUILT" ]; then
  echo "== 1/4  Building == (already done by the caller)"
else
  echo "== 1/4  Building =="
  # The guard stops the build script from calling this pipeline back round again.
  AGENT_WARDEN_NO_AUTO_INSTALL=1 "$ROOT/Scripts/build-app.sh" release >/dev/null
fi
echo "built    : build/AgentWarden.app"

echo
echo "== 2/4  Gates =="
tests_out=$("$ROOT/Scripts/test.sh" 2>&1) || { echo "$tests_out" | tail -30; echo "GATE FAILED: tests"; exit 1; }
echo "tests    : $(printf '%s' "$tests_out" | grep -oE 'Test run with [0-9]+ tests in [0-9]+ suites' | tail -1)"

smoke_out=$("$ROOT/Scripts/smoke-test.sh" 2>&1) || { echo "$smoke_out" | tail -30; echo "GATE FAILED: smoke"; exit 1; }
echo "smoke    : $(printf '%s' "$smoke_out" | grep -oE 'passed: [0-9]+ +failed: [0-9]+' | tail -1)"

ui_out=$("$ROOT/build/AgentWarden.app/Contents/MacOS/AgentWarden" --uicheck 2>&1) || {
  printf '%s' "$ui_out" | grep '✘' | head -20; echo "GATE FAILED: ui check"; exit 1; }
echo "ui check : $(printf '%s' "$ui_out" | grep -c '✔') checks, $(printf '%s' "$ui_out" | grep -c '✘') failures"

echo
echo "== 3/4  Verifying the bundle =="
if [ -z "$INSTALL" ]; then
  /usr/bin/python3 "$ROOT/Scripts/install-app.py" --dry-run "${EXTRA[@]+"${EXTRA[@]}"}"
  echo
  echo "== 4/4  Not installing (--no-install) =="
  exit 0
fi

echo
echo "== 4/4  Installing =="
/usr/bin/python3 "$ROOT/Scripts/install-app.py" $DRY_RUN "${EXTRA[@]+"${EXTRA[@]}"}"

echo
echo "Done in $(( $(date +%s) - started ))s."
