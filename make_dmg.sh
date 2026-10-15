#!/bin/zsh
# CanvasBar DMG 安装盘制作（拖拽式）：需先跑 ./package.sh 产出 dist/CanvasBar-<版本>/
# 布局：窗口 520×380、图标 120px、app 左 · Applications 右 · README 居中下
# 靠 dmgbuild 直写 .DS_Store 生成定制布局（Finder AppleScript 会被 TCC 拒，勿用）
set -e
cd "$(dirname "$0")"

VERSION=${1:-2.9.0}
APP=CanvasBar
STAGE="$PWD/dist/$APP-$VERSION"
DMG="$PWD/dist/$APP-$VERSION.dmg"
VOL="$APP $VERSION"

[ -d "$STAGE/$APP.app" ] || { echo "缺 $STAGE —— 先跑 ./package.sh"; exit 1; }

# 找 dmgbuild（优先本机托管 venv，其次 PATH）
DMGBUILD=""
if [ -x "$HOME/.workbuddy/binaries/python/envs/default/bin/dmgbuild" ]; then
    DMGBUILD="$HOME/.workbuddy/binaries/python/envs/default/bin/dmgbuild"
elif command -v dmgbuild >/dev/null 2>&1; then
    DMGBUILD="$(command -v dmgbuild)"
else
    echo "缺 dmgbuild：pip install dmgbuild"; exit 1
fi

SETTINGS=$(mktemp -t canvasbar-dmg.XXXXXX)
trap 'rm -f "$SETTINGS"' EXIT

cat > "$SETTINGS" <<PYEOF
volume_name = "$VOL"
format = "UDZO"
files = ["$STAGE/$APP.app", "$STAGE/README-使用说明.txt"]
symlinks = {"Applications": "/Applications"}
icon_size = 120
window_rect = ((260, 220), (520, 380))
icon_locations = {
    "$APP.app": (130, 190),
    "Applications": (390, 190),
    "README-使用说明.txt": (260, 300),
}
PYEOF

"$DMGBUILD" -s "$SETTINGS" "$VOL" "$DMG"

hdiutil verify "$DMG"
shasum -a 256 "$DMG"
echo "▸ DMG 完成：$DMG"
