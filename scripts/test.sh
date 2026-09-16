#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Some Command Line Tools releases omit this plugin from Swift Build discovery.
SWIFT_BIN="$(xcrun --find swift)"
TEST_PLUGIN="$(dirname "$(dirname "$SWIFT_BIN")")/lib/swift/host/plugins/testing/libTestingMacros.dylib"
ARGS=(--disable-xctest)
if [ -f "$TEST_PLUGIN" ]; then
    ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN")
fi
swift test "${ARGS[@]}" "$@"
