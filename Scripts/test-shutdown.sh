#!/bin/bash
set -euo pipefail
if [ "$#" != 2 ]; then printf '%s\n' '用法：./Scripts/test-shutdown.sh /路径/CrossOver.app 容器名称' >&2; exit 2; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINE="$1/Contents/SharedSupport/CrossOver/bin/wine"
ZIG="${ZIG:-$(command -v zig || true)}"
if [ ! -x "$WINE" ] || [ ! -x "$ZIG" ]; then printf '%s\n' '需要有效的 CrossOver 应用路径和 Zig。' >&2; exit 1; fi
mkdir -p "$ROOT/Build/Tests"
"$ZIG" cc -target x86_64-windows-gnu -O2 -shared "$ROOT/Tests/ShutdownStub.c" -o "$ROOT/Build/Tests/shutdown-stub.dll"
"$ZIG" cc -target x86_64-windows-gnu -O2 "$ROOT/Tests/ShutdownProbe.c" -o "$ROOT/Build/Tests/shutdown-probe.exe" -municode -luser32 -lgdi32 -lws2_32 -lbcrypt
WINDOWS_ROOT="Z:${ROOT//\//\\}"
"$WINE" --bottle "$2" --cx-app "$WINDOWS_ROOT\\Build\\Tests\\shutdown-probe.exe" "$WINDOWS_ROOT\\Build\\Tests\\shutdown-stub.dll"
