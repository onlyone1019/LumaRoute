#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP="${1:-$ROOT_DIR/dist/LumaRoute.app}"
[ -d "$APP" ] || { echo '请先运行 ./script/build_and_run.sh --build-only' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
ARCH=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/LumaRoute")
case "$ARCH" in arm64|x86_64) ;; *) echo "暂不支持打包架构：$ARCH" >&2; exit 1;; esac
for file in Contents/Library/LaunchServices/LumaRouteHelper Contents/Resources/mihomo; do
  [ "$(/usr/bin/lipo -archs "$APP/$file")" = "$ARCH" ] || { echo "内核或后台服务架构不匹配：$file" >&2; exit 1; }
done
for file in Contents/Resources/install-local-network-service.command Contents/Resources/install_local_service.sh; do
  [ -x "$APP/$file" ] || { echo "缺少可执行安装资源：$file" >&2; exit 1; }
done
TAG="v$VERSION-build.$BUILD"
OUTPUT="$ROOT_DIR/dist/releases/$TAG"
STEM="LumaRoute-$VERSION-build.$BUILD-macos-$ARCH"
mkdir -p "$OUTPUT"
for suffix in dmg zip; do
  [ ! -e "$OUTPUT/$STEM.$suffix" ] || { echo "安装包已存在，保留原文件：$OUTPUT/$STEM.$suffix" >&2; exit 1; }
done
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/LumaRoute-package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$APP" "$STAGING/LumaRoute.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/安装说明.txt" <<EOF
LumaRoute $VERSION · Build $BUILD · $ARCH

需要 macOS 14 或更新版本。arm64 适用于 Apple Silicon，x86_64 适用于 Intel。

安装：
1. 更新旧版前，关闭 LumaRoute 的系统代理和 TUN，再退出应用。
2. 把 LumaRoute.app 放到 /Applications/LumaRoute.app；更新时替换该位置的应用，然后打开。
3. 更新后如出现“完成更新”，点击并在 macOS 管理员授权窗口中确认。
4. 首次使用可点击“启用网络功能”，或直接开启系统代理 / TUN 进入授权。
5. 授权后自动连接服务，无需打开 Terminal、重启或手动重新检查。
6. 自行导入订阅并选择节点；从网络开关进入授权时，会继续应用刚才的选择。

主窗口打开或最小化时保留 Dock 图标，关闭全部主窗口后隐藏。
可从菜单栏重新打开控制台，应用继续在后台运行。

本包使用本地 ad-hoc 签名，未使用 Developer ID 证书，也未公证。
浏览器下载后可能被 macOS Gatekeeper 阻止。确认来源后，可在
“系统设置 → 隐私与安全性”按系统提示手动允许打开。
macOS 仍不允许打开时，可从仓库按 README 在本机自行构建。
无需关闭 Gatekeeper 或系统完整性保护。

后台服务绑定具体构建；需要同步的新版本通过“完成更新”统一授权。
同一已授权版本正常重开不会重复安装。管理员密码只在本机 macOS
授权窗口输入，不要发送到聊天、工单或仓库；应用不会保存密码。
默认混合端口 19790，控制端口 19791；与其他代理工具共存时避免端口冲突。
应用业务数据及密钥保存在
~/Library/Application Support/LumaRoute/lumaroute.sqlite，不再访问钥匙串。
从 Build 21 及以后版本更新会保留现有 SQLite 业务数据。
从 Build 20 或更早版本更新不自动迁移旧 JSON、订阅文件或钥匙串数据，
需重新添加订阅，旧文件原样保留。普通备份不包含完整订阅链接和控制密钥，
恢复时请选择包含 lumaroute.sqlite 的新版备份目录。

项目：https://github.com/onlyone1019/LumaRoute
EOF
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$STEM.zip"
/usr/bin/hdiutil create -volname "LumaRoute $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUTPUT/$STEM.dmg"
(
  cd "$OUTPUT"
  /usr/bin/shasum -a 256 "LumaRoute-$VERSION-build.$BUILD-macos-"*.dmg "LumaRoute-$VERSION-build.$BUILD-macos-"*.zip > "$STAGING/SHA256SUMS.txt"
  mv "$STAGING/SHA256SUMS.txt" SHA256SUMS.txt
)
echo "Release artifacts: $OUTPUT"
