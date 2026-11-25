#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET=15.0
BUILD="$ROOT/Build"
PRODUCTS="$BUILD/Products"
APP="$PRODUCTS/蓝原SDK修复.app"
PAYLOAD="$APP/Contents/Resources/Payload"
VERSION="$(cat "$ROOT/VERSION")"
ZIG="${ZIG:-$(command -v zig || true)}"
if [ -z "$ZIG" ]; then
    for candidate in /opt/homebrew/bin/zig /usr/local/bin/zig; do
        if [ -x "$candidate" ]; then ZIG="$candidate"; break; fi
    done
fi
if [ ! -x "$ZIG" ]; then printf '%s\n' '缺少 Zig。请安装 Zig 0.16.0，或设置 ZIG 为可执行文件的绝对路径。' >&2; exit 1; fi
if [ "$(uname -m)" != arm64 ]; then printf '%s\n' '此构建面向 Apple Silicon，请在原生 arm64 终端或 Xcode 中构建。' >&2; exit 1; fi
mkdir -p "$PRODUCTS" "$BUILD/Cache" "$BUILD/Modules"
ARCHIVE="$BUILD/Cache/endfield-wine-modules.tar.gz"
MODULE_URL="$(plutil -extract finewine.url raw -o - "$ROOT/dependencies.lock.json")"
MODULE_SHA="$(plutil -extract finewine.sha256 raw -o - "$ROOT/dependencies.lock.json")"
if [ ! -f "$ARCHIVE" ]; then
    curl --fail --location --retry 3 "$MODULE_URL" -o "$ARCHIVE.download"
    mv "$ARCHIVE.download" "$ARCHIVE"
fi
ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$MODULE_SHA" ]; then printf '%s\n' 'FineWine 下载包校验失败。请删除 Build/Cache 中的归档后重试。' >&2; exit 1; fi
rm -rf "$APP" "$BUILD/Modules" "$BUILD/DMG"
mkdir -p "$PAYLOAD/bin" "$BUILD/Modules"
tar -xzf "$ARCHIVE" -C "$BUILD/Modules"
MODULES="$BUILD/Modules/endfield-wine-modules"
(cd "$MODULES" && shasum -a 256 -c SHA256SUMS)
cp -R "$MODULES" "$PAYLOAD/modules"
printf '%s\n' '生成应用与磁盘图标…'
xcrun swiftc -swift-version 6 -parse-as-library -O -framework AppKit "$ROOT/Scripts/IconTool.swift" -o "$BUILD/icon-tool"
"$BUILD/icon-tool" --generate "$ROOT/Resources/AppIcon.png" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf '%s\n' '编译 Windows SDK 桥接组件…'
"$ZIG" cc -target x86_64-windows-gnu -O2 "$ROOT/Sources/Bridge/sdk-bridge-host.c" -o "$PAYLOAD/bin/azur-sdk-host.exe" -municode -luser32 -lgdi32 -lws2_32 -lbcrypt
"$ZIG" cc -target x86_64-windows-gnu -O2 -shared "$ROOT/Sources/Bridge/sdk-bridge-proxy.c" "$ROOT/Sources/Bridge/sdk-bridge.def" -o "$PAYLOAD/bin/union_pcsdk.dll" -luser32
"$ZIG" cc -target x86_64-windows-gnu -O2 "$ROOT/Sources/Bridge/policy-browser.c" -o "$PAYLOAD/bin/azur-policy-browser.exe" -municode -lcrypt32 -lws2_32
find "$PAYLOAD/bin" -name '*.pdb' -delete
find "$PAYLOAD/bin" -name '*.lib' -delete
printf '%s\n' '编译原生 SDK 界面…'
LOGIN="$PAYLOAD/bin/AzurAccountLogin.app"
mkdir -p "$LOGIN/Contents/MacOS"
xcrun swiftc -swift-version 6 -target arm64-apple-macos15.0 -O -framework AppKit -framework WebKit "$ROOT/Sources/NativeLogin/NativeLogin.swift" "$ROOT/Sources/NativeLogin/NativeControls.swift" "$ROOT/Sources/NativeLogin/GameWindow.swift" "$ROOT/Sources/NativeLogin/CaptchaBrowser.swift" -o "$LOGIN/Contents/MacOS/azur-login-ui"
cat > "$LOGIN/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.azursdkrepair.native-login</string>
<key>CFBundleName</key><string>AzurAccountLogin</string>
<key>CFBundleExecutable</key><string>azur-login-ui</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$LOGIN"
printf '%s\n' '编译安装与恢复工具…'
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 6 -target arm64-apple-macos15.0 -O -framework AppKit "$ROOT/Sources/Manager/RepairEngine.swift" "$ROOT/Sources/Manager/ManagerMain.swift" -o "$APP/Contents/MacOS/AzurSDKManager"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.azursdkrepair.manager</string>
<key>CFBundleName</key><string>ManjuuSDKFix</string>
<key>CFBundleDisplayName</key><string>ManjuuSDKFix</string>
<key>CFBundleExecutable</key><string>AzurSDKManager</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
cp "$ROOT/LICENSE" "$ROOT/README.md" "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/dependencies.lock.json" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$BUILD/DMG"
ditto "$APP" "$BUILD/DMG/蓝原SDK修复.app"
ln -s /Applications "$BUILD/DMG/Applications"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$BUILD/DMG/"
cp "$BUILD/AppIcon.icns" "$BUILD/DMG/.VolumeIcon.icns"
DMG="$PRODUCTS/蓝原SDK修复-$VERSION.dmg"
WRITABLE="$BUILD/DMG-working.dmg"
MOUNTPOINT="$BUILD/DMG-mount"
mkdir -p "$MOUNTPOINT"
ICON_MOUNTED=0
cleanup_icon_mount() {
    if [ "$ICON_MOUNTED" = 1 ]; then hdiutil detach "$MOUNTPOINT" -quiet || true; fi
}
trap cleanup_icon_mount EXIT
rm -f "$DMG" "$WRITABLE"
hdiutil create -volname '蓝原SDK修复' -srcfolder "$BUILD/DMG" -format UDRW -ov "$WRITABLE"
hdiutil attach -quiet -nobrowse -readwrite -mountpoint "$MOUNTPOINT" "$WRITABLE"
ICON_MOUNTED=1
xcrun SetFile -a C "$MOUNTPOINT"
hdiutil detach "$MOUNTPOINT" -quiet
ICON_MOUNTED=0
hdiutil convert "$WRITABLE" -format UDZO -o "$DMG"
"$BUILD/icon-tool" --set "$BUILD/AppIcon.icns" "$DMG"
rm -f "$WRITABLE"
rmdir "$MOUNTPOINT"
trap - EXIT
shasum -a 256 "$DMG" > "$DMG.sha256"
printf '\n%s\n' "构建完成：$DMG"
