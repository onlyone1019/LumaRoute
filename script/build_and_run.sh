#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="LumaRoute"
BUNDLE_ID="app.lumaroute.desktop"
APP_BUNDLE="$ROOT_DIR/dist/LumaRoute.app"
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
ARCH="$(uname -m)"
if [ ! -x "Resources/Core/mihomo-$ARCH" ]; then python3 script/fetch_core.py; fi
if [ ! -f Resources/GeoData/geoip.metadb ] || [ ! -f Resources/GeoData/GeoIP.dat ] || [ ! -f Resources/GeoData/GeoSite.dat ]; then python3 script/fetch_geodata.py; fi
SDK_PATH="${LUMAROUTE_SDK:-$(xcrun --show-sdk-path)}"
SDK_PATH="$(cd "$SDK_PATH" && pwd -P)"
# CLT 27 ships State macros without the SwiftUIMacros plugin. Use the installed
# stable SDK in this case; never change the user's global developer directory.
if [[ "$SDK_PATH" == *MacOSX27* ]] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ] && [ ! -f /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib ]; then
  SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
BUILD_CONFIGURATION="${LUMAROUTE_BUILD_CONFIGURATION:-release}"
if [ "$MODE" = "--debug" ]; then BUILD_CONFIGURATION=debug; fi
swift build --configuration "$BUILD_CONFIGURATION" --sdk "$SDK_PATH"
BUILD_DIR="$(swift build --configuration "$BUILD_CONFIGURATION" --sdk "$SDK_PATH" --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/Licenses" "$APP_BUNDLE/Contents/Library/LaunchServices" "$APP_BUNDLE/Contents/Library/LaunchDaemons"
/bin/bash "$ROOT_DIR/script/build_app_icon.sh" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$BUILD_DIR/LumaRoute" "$APP_BUNDLE/Contents/MacOS/LumaRoute"
cp "$BUILD_DIR/LumaRouteHelper" "$APP_BUNDLE/Contents/Library/LaunchServices/LumaRouteHelper"
cp "Resources/Core/mihomo-$ARCH" "$APP_BUNDLE/Contents/Resources/mihomo"
cp Resources/Licenses/* "$APP_BUNDLE/Contents/Resources/Licenses/"
cp Resources/MenuBar/ClashX-menu-icon@2x.png "$APP_BUNDLE/Contents/Resources/"
cp script/install_local_service.sh script/install-local-service.command script/install-local-network-service.command script/uninstall-local-service.command "$APP_BUNDLE/Contents/Resources/"
chmod +x "$APP_BUNDLE/Contents/Resources/"*.command
install -m 644 .build/checkouts/Yams/LICENSE "$APP_BUNDLE/Contents/Resources/Licenses/Yams-LICENSE"
mkdir -p "$APP_BUNDLE/Contents/Resources/GeoData"
cp Resources/GeoData/* "$APP_BUNDLE/Contents/Resources/GeoData/"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LumaRoute</string>
<key>CFBundleIdentifier</key><string>app.lumaroute.desktop</string>
<key>CFBundleName</key><string>LumaRoute</string>
<key>CFBundleDisplayName</key><string>LumaRoute</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>19</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
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
/usr/bin/codesign --force --sign "$IDENTITY" --identifier app.lumaroute.core "$APP_BUNDLE/Contents/Resources/mihomo"
/usr/bin/codesign --force --sign "$IDENTITY" --identifier app.lumaroute.helper "$APP_BUNDLE/Contents/Library/LaunchServices/LumaRouteHelper"
/usr/bin/codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
case "$MODE" in
  --build-only) echo "$APP_BUNDLE";;
  run) /usr/bin/open -n "$APP_BUNDLE";;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/LumaRoute";;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "LumaRoute"';;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "app.lumaroute.desktop"';;
  *) echo "usage: $0 [run|--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2;;
esac

