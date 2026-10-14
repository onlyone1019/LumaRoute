#!/bin/bash
set -euo pipefail
RESOURCE_DIR="$(cd "$(dirname "$0")" && pwd -P)"
APP_PATH="$(cd "$RESOURCE_DIR/../.." && pwd -P)"
echo '安装 LumaRoute 本机网络服务：无需开发者证书，不自动开启 TUN 或系统代理。'
echo '管理员密码由 sudo 在本终端中读取；不会发送给应用。'
sudo /bin/bash "$RESOURCE_DIR/install_local_service.sh" --install "$APP_PATH" --network-ready
read -r -p '按回车关闭此窗口…' task_reply
