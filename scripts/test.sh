#!/bin/sh
# Command Line Tools 환경에서는 Swift Testing 매크로 플러그인 경로를 명시해야 한다.
set -e
cd "$(dirname "$0")/.."
PLUGIN_DIR="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGIN_DIR" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" "$@"
else
  exec swift test "$@"
fi
