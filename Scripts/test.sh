#!/bin/bash
# Run the test suite.
#
# With Xcode installed, `swift test` works on its own. With only the Command Line Tools,
# swift-testing ships as a framework outside the default search paths, so we point the compiler
# and the loader at it. Both cases end up running the same tests.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVELOPER_DIR="$(xcode-select -p)"
CLT_FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
CLT_LIBS="$DEVELOPER_DIR/Library/Developer/usr/lib"

EXTRA_FLAGS=()
if [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
  EXTRA_FLAGS=(
    -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS"
    -Xlinker -F -Xlinker "$CLT_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$CLT_LIBS"
  )
fi

# Belt and braces: never let a test run touch the real data directory.
export AGENT_ATTENTION_HOME="${TMPDIR:-/tmp}/agent-attention-test-home"
rm -rf "$AGENT_ATTENTION_HOME"
mkdir -p "$AGENT_ATTENTION_HOME"

swift test "${EXTRA_FLAGS[@]}" "$@"
