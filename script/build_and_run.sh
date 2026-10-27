#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/script/build_environment.sh"
APP_NAME="LumaRoute"
BUNDLE_ID="app.lumaroute.desktop"
APP_BUNDLE="$ROOT_DIR/dist/LumaRoute.app"
ARCH="${LUMAROUTE_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "不支持的构建架构：$ARCH" >&2; exit 1;; esac
if [ -n "${LUMAROUTE_ARCH:-}" ]; then APP_BUNDLE="$ROOT_DIR/dist/$ARCH/LumaRoute.app"; fi
if [ "$MODE" != "--build-only" ]; then
  if pgrep -x "$APP_NAME" >/dev/null; then
    pkill -TERM -u "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1 || true
    for i in $(seq 1 40); do
      if ! pgrep -x "$APP_NAME" >/dev/null; then break; fi
      sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "LumaRoute has not finished restoring networking; build cancelled." >&2
      exit 1
    fi
  fi
fi
if [ ! -x "Resources/Core/mihomo-$ARCH" ]; then python3 script/fetch_core.py; fi
python3 script/fetch_geodata.py
BUILD_CONFIGURATION="${LUMAROUTE_BUILD_CONFIGURATION:-release}"
if [ "$MODE" = "--debug" ]; then BUILD_CONFIGURATION=debug; fi
BUILD_ARGS=(--build-system native --configuration "$BUILD_CONFIGURATION" --sdk "$SDK_PATH" --triple "$ARCH-apple-macosx14.0")
SCRATCH_DIR="$ROOT_DIR/.build"
if [ -n "${LUMAROUTE_ARCH:-}" ]; then
  SCRATCH_DIR="$ROOT_DIR/.build/$ARCH"
  BUILD_ARGS+=(--scratch-path "$SCRATCH_DIR")
fi
swift build "${BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
python3 script/verify_macos_sdk.py "$BUILD_DIR/LumaRoute" "$BUILD_DIR/LumaRouteHelper" "$BUILD_DIR/LumaRouteCLI"
for product in LumaRoute LumaRouteHelper; do
  [ "$(/usr/bin/lipo -archs "$BUILD_DIR/$product")" = "$ARCH" ] || { echo "构建产物架构不匹配：$product" >&2; exit 1; }
done
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/Licenses" "$APP_BUNDLE/Contents/Library/LaunchServices" "$APP_BUNDLE/Contents/Library/LaunchDaemons"
SPARKLE_ROOT="$SCRATCH_DIR/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
install -m 644 "$SPARKLE_ROOT/LICENSE" "$APP_BUNDLE/Contents/Resources/Licenses/Sparkle-LICENSE"
/bin/bash "$ROOT_DIR/script/build_app_icon.sh" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$BUILD_DIR/LumaRoute" "$APP_BUNDLE/Contents/MacOS/LumaRoute"
cp "$BUILD_DIR/LumaRouteHelper" "$APP_BUNDLE/Contents/Library/LaunchServices/LumaRouteHelper"
cp "Resources/Core/mihomo-$ARCH" "$APP_BUNDLE/Contents/Resources/mihomo"
cp Resources/Licenses/* "$APP_BUNDLE/Contents/Resources/Licenses/"
cp Resources/MenuBar/LumaRoute-menu-cat*.png "$APP_BUNDLE/Contents/Resources/"
# Existing output bundles may still contain the historical third-party icon.
rm -f "$APP_BUNDLE/Contents/Resources/ClashX-menu-icon@2x.png"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP_BUNDLE/Contents/Resources/Licenses/"
cp script/install_local_service.sh script/install-local-service.command script/install-local-network-service.command script/uninstall-local-service.command "$APP_BUNDLE/Contents/Resources/"
chmod +x "$APP_BUNDLE/Contents/Resources/"*.command
install -m 644 "$SCRATCH_DIR/checkouts/Yams/LICENSE" "$APP_BUNDLE/Contents/Resources/Licenses/Yams-LICENSE"
mkdir -p "$APP_BUNDLE/Contents/Resources/GeoData"
cp Resources/GeoData/geoip.metadb Resources/GeoData/GeoIP.dat Resources/GeoData/GeoSite.dat Resources/GeoData/GeoSite-policy.json Resources/GeoData/release.json "$APP_BUNDLE/Contents/Resources/GeoData/"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LumaRoute</string>
<key>CFBundleIdentifier</key><string>app.lumaroute.desktop</string>
<key>CFBundleName</key><string>LumaRoute</string>
<key>CFBundleDisplayName</key><string>LumaRoute</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string></array>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.12</string>
<key>CFBundleVersion</key><string>42</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 onlyone1019</string>
<key>LSUIElement</key><false/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$APP_BUNDLE/Contents/Info.plist" "$ROOT_DIR/Resources/Core/release.json" "$ROOT_DIR/Resources/Sparkle/public-key.txt" "$ARCH" <<'PY'
import json, plistlib, re, sys
from pathlib import Path
path = Path(sys.argv[1])
version = json.loads(Path(sys.argv[2]).read_text())["version"]
if not isinstance(version, str) or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("Invalid bundled core version")
info = plistlib.loads(path.read_bytes())
info["LumaRouteCoreVersion"] = version
import base64
key = Path(sys.argv[3]).read_text().strip()
if len(base64.b64decode(key, validate=True)) != 32:
    raise SystemExit("Invalid Sparkle public key")
info["SUPublicEDKey"] = key
info["SUFeedURL"] = "https://github.com/onlyone1019/LumaRoute/releases/latest/download/appcast-" + sys.argv[4] + ".xml"
info["SUEnableAutomaticChecks"] = False
info["SUAllowsAutomaticUpdates"] = False
info["SUAutomaticallyUpdate"] = False
info["SUEnableSystemProfiling"] = False
info["SURequireSignedFeed"] = True
info["SUVerifyUpdateBeforeExtraction"] = True
path.write_bytes(plistlib.dumps(info))
PY
cat > "$APP_BUNDLE/Contents/Library/LaunchDaemons/app.lumaroute.helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>app.lumaroute.helper</string>
<key>UserName</key><string>root</string>
<key>BundleProgram</key><string>Contents/Library/LaunchServices/LumaRouteHelper</string>
<key>MachServices</key><dict><key>app.lumaroute.helper</key><true/></dict>
<key>AssociatedBundleIdentifiers</key><array><string>app.lumaroute.desktop</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
</dict></plist>
PLIST
chmod +x "$APP_BUNDLE/Contents/MacOS/LumaRoute" "$APP_BUNDLE/Contents/Library/LaunchServices/LumaRouteHelper" "$APP_BUNDLE/Contents/Resources/mihomo"
IDENTITY="${LUMAROUTE_SIGNING_IDENTITY:--}"
if [ "$IDENTITY" != '-' ]; then
  # Re-sign nested Sparkle executables from the inside out for distribution.
  SPARKLE_VERSION="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
  for nested in XPCServices/Downloader.xpc XPCServices/Installer.xpc Updater.app Autoupdate; do
    /usr/bin/codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_VERSION/$nested"
  done
  /usr/bin/codesign --force --options runtime --sign "$IDENTITY" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi
/usr/bin/codesign --force --sign "$IDENTITY" --identifier app.lumaroute.core "$APP_BUNDLE/Contents/Resources/mihomo"
/usr/bin/codesign --force --sign "$IDENTITY" --identifier app.lumaroute.helper "$APP_BUNDLE/Contents/Library/LaunchServices/LumaRouteHelper"
/usr/bin/codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
# Reusing the output directory leaves its old modification date intact.
# Launch Services uses the bundle date to decide whether to refresh metadata.
touch "$APP_BUNDLE"
case "$MODE" in
  --build-only) echo "$APP_BUNDLE";;
  run) /usr/bin/open -n "$APP_BUNDLE";;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/LumaRoute";;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "LumaRoute"';;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "app.lumaroute.desktop"';;
  *) echo "usage: $0 [run|--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2;;
esac

