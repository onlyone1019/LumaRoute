#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP="$ROOT_DIR/dist/LumaRoute.app"
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
2. 把 LumaRoute.app 拖到 Applications（应用程序），替换旧版后打开。
3. 在“设置 → 网络 → 管理服务”中选择“安装并授权网络服务”。
4. 在 Terminal 手动输入管理员密码；安装完成后应用自动刷新。
5. 自行导入订阅、选择节点，再启用系统代理或 TUN。

本包使用本地 ad-hoc 签名，未使用 Developer ID 证书，也未公证。
浏览器下载后可能被 macOS Gatekeeper 阻止。确认来源后，可在
“系统设置 → 隐私与安全性”按系统提示手动允许打开。
macOS 仍不允许打开时，可从仓库按 README 在本机自行构建。
无需关闭 Gatekeeper 或系统完整性保护。

后台服务绑定具体构建；每次替换新版本后请重新安装同步服务。
管理员密码只在本机 Terminal 输入，不要发送到聊天、工单或仓库。
默认混合端口 19790，控制端口 19791；与其他代理工具共存时避免端口冲突。
应用数据保存在 ~/Library/Application Support/LumaRoute，订阅链接保存在钥匙串。

项目：https://github.com/onlyone1019/LumaRoute
EOF
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$STEM.zip"
/usr/bin/hdiutil create -volname "LumaRoute $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUTPUT/$STEM.dmg"
(
  cd "$OUTPUT"
  /usr/bin/shasum -a 256 "$STEM.dmg" "$STEM.zip" > SHA256SUMS.txt
)
echo "Release artifacts: $OUTPUT"
