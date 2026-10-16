# Dock 启动修复与标准安装路径

标准安装位置为 `/Applications/LumaRoute.app`。用户于 2026-10-16 明确撤回通过嵌套目录安装的方案，要求在代码中修复 Dock 显示。历史路径对照保留为排查记录，不再作为安装要求或系统缓存根因结论。

## 修改

- 应用包的 `LSUIElement` 改为 `false`，启动时使用普通应用的 `regular` 激活策略。
- 首个 SwiftUI 主窗口异步创建期间保持待显示状态，避免尚未注册窗口时被误判为“全部关闭”而切换到 `accessory`。
- 主窗口出现后再执行首次激活；关闭最后一个主窗口后隐藏 Dock，菜单栏继续运行。最小化保留 Dock，从菜单栏或 Dock 重开仍使用原窗口管理逻辑。
- README 和打包安装说明统一使用 `/Applications/LumaRoute.app`。页面、主题及日志和页面缓存优化未改动。

## 验证

`python3 script/check_dock_lifecycle.py` 在已登录的 macOS 桌面中编译并运行生产 `AppDelegate`，仅替换网络和存储依赖，不接触真实代理或订阅。检查真实 NSWindow 通知、延迟注册、最小化、关闭、重开及多窗口行为。修改前 4 项启动检查失败，修改后 13 项全部通过。该检查覆盖激活策略及窗口生命周期，实际 Dock 渲染仍需视觉验收。

通过 `./script/build_and_run.sh --build-only` 构建，完整包签名校验通过；整体安装到 `/Applications/LumaRoute.app` 后，安装二进制与构建产物哈希一致。用户确认该路径下 Dock 图标正常显示。

安装前后 SQLite 完整性均正常；app_state、profiles、custom_rules、group_strategies、rule_subscriptions、choices 表内容一致。系统代理配置未变，Clash Verge 内核和原 LumaRoute 后台服务进程未重启。按用户要求，LumaRoute 未接管系统代理或 TUN，也未执行新构建的后台服务授权。

发布版本为 [0.1.3 · Build 33](releases/v0.1.3.md)。
