#!/usr/bin/env bash
# Source from build/test entry points; never change xcode-select globally.
lumaroute_configure_build_environment() {
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "需要包含 macOS 27.0 SDK 的完整 Xcode，请设置 DEVELOPER_DIR。" >&2
    return 1
  fi
  local selected_sdk sdk_version platform_plugins
  selected_sdk="${LUMAROUTE_SDK:-$(/usr/bin/xcrun --sdk macosx27.0 --show-sdk-path)}" || return 1
  SDK_PATH="$(cd "$selected_sdk" && pwd -P)" || return 1
  sdk_version="$(/usr/libexec/PlistBuddy -c 'Print :Version' "$SDK_PATH/SDKSettings.plist")" || return 1
  if [ "$sdk_version" != "27.0" ]; then
    echo "构建固定使用 macOS 27.0 SDK，实际选择：$sdk_version ($SDK_PATH)" >&2
    return 1
  fi
  platform_plugins="${SDK_PATH%/SDKs/*}/usr/lib/swift/host/plugins"
  if [ ! -f "$platform_plugins/libSwiftUIMacros.dylib" ]; then
    echo "所选 SDK 缺少 SwiftUI 宏插件，请使用完整 Xcode 的 macOS 27.0 SDK。" >&2
    return 1
  fi
  # /usr/bin/swift's launcher and clang also consult SDKROOT. Match --sdk.
  export SDKROOT="$SDK_PATH"
}
lumaroute_configure_build_environment
