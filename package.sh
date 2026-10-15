#!/bin/zsh
# CanvasBar 发布打包脚本：
#   双架构编译（arm64 + x86_64，最低 macOS 13）→ 通用二进制 .app → ad-hoc 签名 → 带源码 zip
# 产物：dist/CanvasBar-<版本>-universal.zip
set -e
cd "$(dirname "$0")"

APP=CanvasBar
VERSION=2.9.0
DEPLOY=13.0   # 最低支持 macOS 13
DIST="$PWD/dist"
NAME="$APP-$VERSION"
STAGE="$DIST/$NAME"
ZIP="$DIST/$APP-$VERSION-universal.zip"

rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE/source" "$STAGE/$APP.app/Contents/MacOS" "$STAGE/$APP.app/Contents/Resources"

BUILD_TMP=$(mktemp -d)
trap 'rm -rf "$BUILD_TMP"' EXIT

echo "▸ 编译 arm64 …"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macosx$DEPLOY CanvasBar.swift -o "$BUILD_TMP/$APP.arm64"
echo "▸ 编译 x86_64 …"
swiftc -O -swift-version 5 -parse-as-library -target x86_64-apple-macosx$DEPLOY CanvasBar.swift -o "$BUILD_TMP/$APP.x86_64"

lipo -create -output "$STAGE/$APP.app/Contents/MacOS/$APP" "$BUILD_TMP/$APP.arm64" "$BUILD_TMP/$APP.x86_64"

if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$STAGE/$APP.app/Contents/Resources/AppIcon.icns"
fi

cat > "$STAGE/$APP.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP</string>
    <key>CFBundleIdentifier</key><string>local.chester.canvasbar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>$APP</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$DEPLOY</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Chester</string>
</dict>
</plist>
PLIST

codesign --force -s - "$STAGE/$APP.app"
codesign --verify --deep --strict "$STAGE/$APP.app"
echo "▸ 签名校验通过"

# 源码随包（便于在目标机重新编译）
cp CanvasBar.swift build.sh package.sh AppIcon.icns "$STAGE/source/"
mkdir -p "$STAGE/source/Assets"
cp Assets/* "$STAGE/source/Assets/" 2>/dev/null || true

cat > "$STAGE/README-使用说明.txt" <<TXT
CanvasBar v$VERSION — PolyU Canvas 菜单栏同步助手（macOS 通用版）
==============================================================

【包内内容】
  CanvasBar.app        主程序（Apple 芯片 + Intel 通用，需 macOS 13 及以上）
  source/              完整源码 + 构建脚本（可在本机重新编译）
  README-使用说明.txt   本文件

【安装与首次打开】
  1) 将 CanvasBar.app 拖入「应用程序」文件夹。
  2) 第一次打开请右键点（或 Control-点击）App 图标，选择「打开」并确认。
     若系统仍提示「无法验证开发者」：
       打开「系统设置 → 隐私与安全性」，在底部找到 CanvasBar，点「仍要打开」；
     或打开「终端」执行一次（路径按实际位置替换）：
       xattr -dr com.apple.quarantine /Applications/CanvasBar.app
     说明：本 App 为本地个人签名，未经过 Apple 公证，属于正常现象，不是恶意软件。

【首次使用】
  1) 启动后菜单栏会出现 CanvasBar 图标；没有 Dock 图标和主窗口，是正常设计（纯菜单栏程序）。
  2) 点菜单栏图标 →「🔑 登录 Canvas…」，在弹出的窗口里完成 PolyU 统一身份认证；
     成功后窗口自动关闭并开始首次同步（本版登录窗已做健壮化处理）。
  3) 首次同步会弹出「访问你的"文档"文件夹」授权请求，请允许。
     同步目标固定为 ~/Documents/Canvas 同步/<课程>/，不写其他任何目录。
  4) 常用操作：点课程名展开子菜单（打开课程页 / 打开文件夹 / 立即同步此课程 /
     关闭该课程），已同步文件若被你重新整理成子文件夹，菜单会按你的文件夹结构实时展示。
  5) 打开文件：悬停某个文件 →「打开（默认应用）」/「打开方式」（选择系统里其它
     可用 App）/「在 Finder 中显示」；目录也有「在 Finder 中显示」。
  6) 检查更新：菜单「⬆️ 检查更新…」对比 GitHub 最新 Release，发现新版本可一键更新
     （自动下载、校验、替换并重启；更新后首次启动可能重新弹一次「文稿文件夹」授权）。

【数据与卸载】
  配置与状态：~/Library/Application Support/CanvasBar/
  同步文件：  ~/Documents/Canvas 同步/
  卸载：菜单退出 App 后，删除上述两个目录及 App 本体即可，无其他残留。

【构建信息】
  通用二进制（arm64 + x86_64），最低 macOS 13，Swift 6.4 编译，ad-hoc 签名。
TXT

ditto -c -k --keepParent "$STAGE" "$ZIP"
echo "▸ 打包完成：$ZIP"
shasum -a 256 "$ZIP"
