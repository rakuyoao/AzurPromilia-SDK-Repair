#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p Build/Tests
for name in PolicyList UserCenter WelcomeLayout; do
    xcrun swiftc -swift-version 6 -O -framework AppKit Sources/NativeLogin/NativeControls.swift "Tests/${name}Probe.swift" -o "Build/Tests/${name}Probe"
    "Build/Tests/${name}Probe"
done
xcrun swiftc -swift-version 6 -O -framework AppKit Sources/Manager/RepairEngine.swift Tests/ContainerEntryProbe.swift -o Build/Tests/ContainerEntryProbe
Build/Tests/ContainerEntryProbe
printf '%s\n' '原生控件回归检查完成。'
