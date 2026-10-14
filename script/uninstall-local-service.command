#!/bin/bash
set -euo pipefail
RESOURCE_DIR="$(cd "$(dirname "$0")" && pwd -P)"
sudo /bin/bash "$RESOURCE_DIR/install_local_service.sh" --remove
read -r -p '按回车关闭此窗口…' task_reply
