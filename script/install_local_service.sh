#!/bin/bash
set -euo pipefail
SERVICE_ROOT='/Library/Application Support/LumaRoute/service'
APP_COPY="$SERVICE_ROOT/LumaRoute.app"
LABEL='app.lumaroute.local-helper'
JOB="/Library/LaunchDaemons/$LABEL.plist"
LEGACY_LABEL='app.lumaroute.helper'
LEGACY_JOB="/Library/LaunchDaemons/$LEGACY_LABEL.plist"
MODE="${1:-}"
JOURNAL=''
if [ "$(id -u)" != 0 ] || [ -z "${SUDO_UID:-}" ] || [ "$SUDO_UID" = 0 ]; then
  echo '请从 LumaRoute 的管理员授权窗口或通过 sudo 运行安装器。' >&2
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
  while launchctl print "system/$1" >/dev/null 2>&1; do
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
    fi
  fi
fi
require_network_restored() {
  if [ -n "$JOURNAL" ] && [ -e "$JOURNAL" ]; then
    check_owned "$JOURNAL"
    /usr/bin/python3 - "$JOURNAL" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f:
    records=plistlib.load(f)
    if not isinstance(records,dict) or any(not isinstance(v,dict) for v in records.values()):
        sys.exit('网络恢复记录无效，已保留原服务。')
    if records:
        sys.exit('原服务尚未完成网络恢复，已保留原安装，请稍后重试。')
PY
  fi
}
# Only migrate jobs that belong to this root-owned installation. A managed
# registration without our old absolute-path plist remains a separate job.
for task_job in "$JOB" "$LEGACY_JOB"; do
  if [ -e "$task_job" ]; then
    check_owned "$task_job"
    [ "$(plutil -extract Program raw "$task_job")" = "$APP_COPY/Contents/Library/LaunchServices/LumaRouteHelper" ] || { echo '发现其他安装方式的服务，请先卸载原服务。' >&2; exit 1; }
  fi
done
if [ "$MODE" = '--remove' ]; then
  require_network_restored
  for task_label in "$LABEL" "$LEGACY_LABEL"; do
    if [ -e "/Library/LaunchDaemons/$task_label.plist" ]; then
      if launchctl print "system/$task_label" >/dev/null 2>&1; then launchctl bootout "system/$task_label"; fi
      wait_job_stopped "$task_label"
      rm -f "/Library/LaunchDaemons/$task_label.plist"
    fi
  done
  rm -f "$SERVICE_ROOT/installation.plist"
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
ROLLBACK_NEEDED=false
REPLACED=false
cleanup() {
  local task_result=$?
  trap - EXIT
  if [ "$ROLLBACK_NEEDED" = true ]; then
    if ! rollback_installation; then
      echo "恢复未完成，保留备份，请勿删除：$STAGING" >&2
      exit 1
    fi
  fi
  rm -rf "$STAGING"
  exit "$task_result"
}
trap cleanup EXIT
/usr/bin/ditto "$SOURCE_APP" "$STAGING/LumaRoute.app"
chown -R root:wheel "$STAGING/LumaRoute.app"
chmod -R a+rX,go-w "$STAGING/LumaRoute.app"
codesign --verify --deep --strict "$STAGING/LumaRoute.app"
codesign --verify --strict "$STAGING/LumaRoute.app/Contents/Library/LaunchServices/LumaRouteHelper"
plutil -create xml1 "$STAGING/installation.plist"
plutil -insert ownerUID -integer "$SUDO_UID" "$STAGING/installation.plist"
plutil -insert protocolVersion -integer 1 "$STAGING/installation.plist"
plutil -insert serviceID -string "$LABEL" "$STAGING/installation.plist"
HEALTH_ONLY=true
if [ "${3:-}" = '--network-ready' ]; then HEALTH_ONLY=false; fi
plutil -insert healthOnly -bool "$HEALTH_ONLY" "$STAGING/installation.plist"
cat > "$STAGING/job.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>app.lumaroute.local-helper</string>
<key>Program</key><string>/Library/Application Support/LumaRoute/service/LumaRoute.app/Contents/Library/LaunchServices/LumaRouteHelper</string>
<key>ProgramArguments</key><array><string>/Library/Application Support/LumaRoute/service/LumaRoute.app/Contents/Library/LaunchServices/LumaRouteHelper</string><string>--local</string></array>
<key>UserName</key><string>root</string>
<key>MachServices</key><dict><key>app.lumaroute.local-helper</key><true/></dict>
<key>AssociatedBundleIdentifiers</key><array><string>app.lumaroute.desktop</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ExitTimeOut</key><integer>30</integer>
<key>StandardErrorPath</key><string>/Library/Application Support/LumaRoute/service/startup.log</string>
</dict></plist>
PLIST
plutil -lint "$STAGING/job.plist"
wait_job_started() {
  local task_deadline=$((SECONDS + 10)) task_snapshot task_pid task_program task_last_pid=''
  while (( SECONDS < task_deadline )); do
    task_snapshot=$(launchctl print "system/$LABEL" 2>/dev/null) || task_snapshot=''
    task_pid=$(sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' <<< "$task_snapshot")
    task_program=$(sed -n 's/^[[:space:]]*program = //p' <<< "$task_snapshot")
    if [[ "$task_snapshot" == *"state = running"* &&
          "$task_program" = "$APP_COPY/Contents/Library/LaunchServices/LumaRouteHelper" &&
          "$task_pid" =~ ^[1-9][0-9]*$ ]]; then
      if [ "$task_pid" = "$task_last_pid" ]; then return 0; fi
      task_last_pid="$task_pid"
    else
      task_last_pid=''
    fi
    /bin/sleep 0.2
  done
  echo '后台服务未能正常启动，正在恢复此前安装。' >&2
  return 1
}
rollback_installation() {
  if [ "$REPLACED" = true ]; then
    if launchctl print "system/$LABEL" >/dev/null 2>&1; then
      launchctl bootout "system/$LABEL" || return 1
      wait_job_stopped "$LABEL" || return 1
    fi
    rm -rf "$APP_COPY" || return 1
    rm -f "$JOB" || return 1
    if [ -e "$STAGING/previous.app" ]; then mv "$STAGING/previous.app" "$APP_COPY" || return 1; fi
    if [ -e "$STAGING/previous.plist" ]; then
      cp "$STAGING/previous.plist" "$SERVICE_ROOT/installation.plist" || return 1
    else
      rm -f "$SERVICE_ROOT/installation.plist" || return 1
    fi
  fi
  for task_label in "$LABEL" "$LEGACY_LABEL"; do
    task_job="/Library/LaunchDaemons/$task_label.plist"
    if [ -e "$STAGING/$task_label.plist" ]; then
      cp "$STAGING/$task_label.plist" "$task_job" || return 1
      if [ -e "$STAGING/$task_label.running" ] && ! launchctl print "system/$task_label" >/dev/null 2>&1; then
        launchctl bootstrap system "$task_job" || return 1
      fi
    fi
  done
  echo '加载或启动失败，已恢复此前的安装文件。' >&2
}
# Save all rollback state and validate ownership before stopping either job.
# Existing network journals must be settled; installation never enables takeover.
if [ -e "$APP_COPY" ]; then check_owned "$APP_COPY"; fi
if [ -e "$SERVICE_ROOT/startup.log" ]; then check_owned "$SERVICE_ROOT/startup.log"; fi
if [ -e "$SERVICE_ROOT/installation.plist" ]; then cp "$SERVICE_ROOT/installation.plist" "$STAGING/previous.plist"; fi
for task_label in "$LABEL" "$LEGACY_LABEL"; do
  task_job="/Library/LaunchDaemons/$task_label.plist"
  if [ -e "$task_job" ]; then
    cp "$task_job" "$STAGING/$task_label.plist"
    if launchctl print "system/$task_label" >/dev/null 2>&1; then touch "$STAGING/$task_label.running"; fi
  elif [ "$task_label" = "$LABEL" ] && launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo '存在未归属当前安装器的服务，停止安装。' >&2
    exit 1
  fi
done
ROLLBACK_NEEDED=true
for task_label in "$LABEL" "$LEGACY_LABEL"; do
  if [ -e "$STAGING/$task_label.running" ]; then
    launchctl bootout "system/$task_label"
    wait_job_stopped "$task_label"
  fi
done
# A new ad-hoc build cannot ask the old pinned helper to stop over XPC.
# Let the owned old job exit first, then recover with the staged helper while
# rollback is armed and the old installation is still intact.
if ! require_network_restored 2>/dev/null; then
  "$STAGING/LumaRoute.app/Contents/Library/LaunchServices/LumaRouteHelper" --restore-network-for-maintenance
fi
require_network_restored
if [ -e "$APP_COPY" ]; then mv "$APP_COPY" "$STAGING/previous.app"; fi
REPLACED=true
mv "$STAGING/LumaRoute.app" "$APP_COPY"
install -o root -g wheel -m 644 "$STAGING/installation.plist" "$SERVICE_ROOT/installation.plist"
install -o root -g wheel -m 644 "$STAGING/job.plist" "$JOB"
if [ ! -e "$SERVICE_ROOT/startup.log" ]; then install -o root -g wheel -m 600 /dev/null "$SERVICE_ROOT/startup.log"; fi
if ! launchctl bootstrap system "$JOB" || ! wait_job_started; then exit 1; fi
# Delete the old boot-time definition only after the replacement is running.
rm -f "$LEGACY_JOB"
ROLLBACK_NEEDED=false
echo '服务已启动，尚未开启网络接管。LumaRoute 会自动刷新服务状态并恢复内核，无需重启或点击“重新检查”。'
