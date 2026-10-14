#!/bin/zsh
# CanvasBar 构建脚本：编译 → 打包 .app → ad-hoc 签名
set -e
cd "$(dirname "$0")"

APP=CanvasBar
BUILD="$PWD/.build"
APPDIR="$BUILD/$APP.app"

rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library CanvasBar.swift -o "$APPDIR/Contents/MacOS/$APP"

# 应用图标（Assets/make_appicon.swift 生成；文件存在才拷贝）
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APPDIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APPDIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CanvasBar</string>
    <key>CFBundleIdentifier</key><string>local.chester.canvasbar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>CanvasBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.8.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Chester</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APPDIR" 2>/dev/null || true

echo "Built: $APPDIR"
