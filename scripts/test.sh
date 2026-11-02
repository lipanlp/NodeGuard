#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_ARCH="${NODEGUARD_ARCH:-$(uname -m)}"
TASK_BUILD="$TASK_ROOT/work/build-$TASK_ARCH"
if [[ ! -f "$TASK_BUILD/libNodeGuardCore.a" ]]; then "$TASK_ROOT/scripts/build.sh"; fi
xcrun swiftc -sdk "$(xcrun --show-sdk-path)" -target "$TASK_ARCH-apple-macosx13.0" -O -I "$TASK_BUILD" -I "$TASK_ROOT/Sources/CProcess/include" -I "$TASK_ROOT/Vendor/Yams/Sources/CYaml/include" -L "$TASK_BUILD" -lNodeGuardCore -lYams -lCYaml -lCProcess "$TASK_ROOT"/Tests/NodeGuardCoreTests/*.swift -o "$TASK_BUILD/NodeGuardTests"
"$TASK_BUILD/NodeGuardTests"
