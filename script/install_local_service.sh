#!/bin/bash
set -euo pipefail
SERVICE_ROOT='/Library/Application Support/LumaRoute/service'
APP_COPY="$SERVICE_ROOT/LumaRoute.app"
JOB='/Library/LaunchDaemons/app.lumaroute.helper.plist'
LABEL='app.lumaroute.helper'
MODE="${1:-}"
if [ "$(id -u)" != 0 ] || [ -z "${SUDO_UID:-}" ] || [ "$SUDO_UID" = 0 ]; then
  echo '请由当前用户通过 sudo 运行安装器；管理员密码只在终端中输入。' >&2
  exit 1
fi
check_owned() {
  [ ! -L "$1" ] && [ "$(stat -f %u "$1")" = 0 ] || { echo "服务路径所有权无效：$1" >&2; exit 1; }
  local task_mode
  task_mode=$(stat -f %Lp "$1")
  (( (8#$task_mode & 8#022) == 0 )) || { echo "服务路径不能被其他用户修改：$1" >&2; exit 1; }
}
wait_job_stopped() {
  local task_deadline=$((SECONDS + 35))
  # bootout can return while launchd still exposes a terminating job. Never
  # remove its executable or replace its snapshot until that job is gone.
  while launchctl print "system/$LABEL" >/dev/null 2>&1; do
    if (( SECONDS >= task_deadline )); then
      echo '服务尚未退出，保留文件。请稍后重试。' >&2
      return 1
    fi
    /bin/sleep 0.2
  done
}
for task_dir in '/Library/Application Support/LumaRoute' "$SERVICE_ROOT"; do
  if [ ! -e "$task_dir" ]; then mkdir -m 755 "$task_dir"; fi
  check_owned "$task_dir"
done
if [ -e "$SERVICE_ROOT/installation.plist" ]; then
  check_owned "$SERVICE_ROOT/installation.plist"
  [ "$(plutil -extract ownerUID raw "$SERVICE_ROOT/installation.plist")" = "$SUDO_UID" ] || { echo '此服务属于另一位用户。' >&2; exit 1; }
  if [ "$(plutil -extract healthOnly raw "$SERVICE_ROOT/installation.plist")" != true ]; then
    JOURNAL="/Library/Application Support/LumaRoute/users/$SUDO_UID/network-journal.plist"
    if [ -e "$JOURNAL" ]; then
      check_owned "$JOURNAL"
      /usr/bin/python3 - "$JOURNAL" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f:
    if plistlib.load(f):
        sys.exit('请先在应用中关闭接管并恢复网络，再维护服务。')
PY
    fi
  fi
fi
if [ -e "$JOB" ]; then
  check_owned "$JOB"
  [ "$(plutil -extract Program raw "$JOB")" = "$APP_COPY/Contents/Library/LaunchServices/LumaRouteHelper" ] || { echo '发现其他安装方式的服务，请先卸载原服务。' >&2; exit 1; }
fi
if [ "$MODE" = '--remove' ]; then
  if [ -e "$JOB" ]; then launchctl bootout "system/$LABEL" || true; fi
  wait_job_stopped
  rm -f "$JOB" "$SERVICE_ROOT/installation.plist"
  if [ -e "$APP_COPY" ]; then check_owned "$APP_COPY"; rm -rf "$APP_COPY"; fi
  echo '本机后台服务已卸载；订阅、钥匙串和用户数据均已保留。'
  exit 0
fi
[ "$MODE" = '--install' ] && [ -n "${2:-}" ] || { echo '用法：--install /完整路径/LumaRoute.app 或 --remove' >&2; exit 1; }
SOURCE_APP="$2"
[ -d "$SOURCE_APP" ] && [ ! -L "$SOURCE_APP" ] || { echo '应用路径无效。' >&2; exit 1; }
codesign --verify --deep --strict "$SOURCE_APP"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" = app.lumaroute.desktop ] || { echo '不是 LumaRoute 应用。' >&2; exit 1; }
STAGING=$(mktemp -d "$SERVICE_ROOT/.stage.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$SOURCE_APP" "$STAGING/LumaRoute.app"
chown -R root:wheel "$STAGING/LumaRoute.app"
chmod -R a+rX,go-w "$STAGING/LumaRoute.app"
codesign --verify --deep --strict "$STAGING/LumaRoute.app"
codesign --verify --strict "$STAGING/LumaRoute.app/Contents/Library/LaunchServices/LumaRouteHelper"
plutil -create xml1 "$STAGING/installation.plist"
plutil -insert ownerUID -integer "$SUDO_UID" "$STAGING/installation.plist"
plutil -insert protocolVersion -integer 1 "$STAGING/installation.plist"
HEALTH_ONLY=true
if [ "${3:-}" = '--network-ready' ]; then HEALTH_ONLY=false; fi
plutil -insert healthOnly -bool "$HEALTH_ONLY" "$STAGING/installation.plist"
cat > "$STAGING/job.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>app.lumaroute.helper</string>
<key>Program</key><string>/Library/Application Support/LumaRoute/service/LumaRoute.app/Contents/Library/LaunchServices/LumaRouteHelper</string>
<key>ProgramArguments</key><array><string>/Library/Application Support/LumaRoute/service/LumaRoute.app/Contents/Library/LaunchServices/LumaRouteHelper</string><string>--local</string></array>
<key>UserName</key><string>root</string>
<key>MachServices</key><dict><key>app.lumaroute.helper</key><true/></dict>
<key>AssociatedBundleIdentifiers</key><array><string>app.lumaroute.desktop</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ExitTimeOut</key><integer>30</integer>
<key>StandardErrorPath</key><string>/Library/Application Support/LumaRoute/service/startup.log</string>
</dict></plist>
PLIST
plutil -lint "$STAGING/job.plist"
# Installation never enables network takeover. Existing network journals must
# be settled before replacing a service; the GUI enables takeover explicitly.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  [ -e "$JOB" ] || { echo '存在未归属当前安装器的服务，停止安装。' >&2; exit 1; }
  launchctl bootout "system/$LABEL"
  wait_job_stopped
fi
if [ -e "$APP_COPY" ]; then check_owned "$APP_COPY"; mv "$APP_COPY" "$STAGING/previous.app"; fi
if [ -e "$SERVICE_ROOT/installation.plist" ]; then cp "$SERVICE_ROOT/installation.plist" "$STAGING/previous.plist"; fi
if [ -e "$JOB" ]; then cp "$JOB" "$STAGING/previous-job.plist"; fi
mv "$STAGING/LumaRoute.app" "$APP_COPY"
install -o root -g wheel -m 644 "$STAGING/installation.plist" "$SERVICE_ROOT/installation.plist"
install -o root -g wheel -m 644 "$STAGING/job.plist" "$JOB"
if [ -e "$SERVICE_ROOT/startup.log" ]; then check_owned "$SERVICE_ROOT/startup.log"; else install -o root -g wheel -m 600 /dev/null "$SERVICE_ROOT/startup.log"; fi
if ! launchctl bootstrap system "$JOB"; then
  launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  rm -rf "$APP_COPY"
  if [ -e "$STAGING/previous.app" ]; then mv "$STAGING/previous.app" "$APP_COPY"; fi
  if [ -e "$STAGING/previous.plist" ]; then cp "$STAGING/previous.plist" "$SERVICE_ROOT/installation.plist"; else rm -f "$SERVICE_ROOT/installation.plist"; fi
  if [ -e "$STAGING/previous-job.plist" ]; then cp "$STAGING/previous-job.plist" "$JOB"; launchctl bootstrap system "$JOB" || true; else rm -f "$JOB"; fi
  echo '加载失败，已恢复此前的安装文件。' >&2
  exit 1
fi
echo '服务已加载，尚未开启网络接管。LumaRoute 会自动刷新服务状态并恢复内核，无需重启或点击“重新检查”。'
