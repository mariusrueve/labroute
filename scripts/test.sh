#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
extra=()
# Swift 6.4's Command Line Tools ship Testing as a framework. Swift Build's
# emit-module invocation can omit its discovered macro plugin. Load the shipped
# plugin explicitly when that layout exists; no download or dependency needed.
compiler="$(xcrun --find swiftc)"
plugin="$(dirname "$compiler")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$plugin" ]]; then extra=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
swift test "${extra[@]}" "$@"
