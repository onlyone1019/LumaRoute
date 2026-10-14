# Build 19：应用内完成网络服务授权

原本每次构建变化都需要在“管理服务”中打开 Terminal，再由用户执行安装脚本。Build 19 保留管理员服务对应用构建的精确身份绑定，把检测、授权和自动重连整合到应用内。

## 使用流程

- 服务尚未安装：显示“启用网络功能”。也可以直接开启系统代理或 TUN，完成授权后继续应用该次选择。
- 已有服务与当前应用构建不匹配：启动后显示“完成应用更新”和“完成更新”，不再先弹出启动失败错误。
- 当前构建已授权：正常启动直接运行，不再次提示同步。
- 授权通过 macOS 系统管理员窗口完成；安装脚本作为固定资源执行，应用不接收、保存或传递密码。
- 完成同步后自动刷新服务身份、内核及节点。保留“重新同步服务”作为手动入口，原 `.command` 资源作为兼容入口。
- 取消授权会结束该次请求并清理待应用的开关意图，允许稍后重试；不会自动反复请求管理员密码。

## 实现与边界

`LocalServiceAuthorization` 使用固定的 `/usr/bin/osascript` 进程执行授权脚本，耗时操作不会阻塞主界面。路径用 AppleScript 的 `quoted form` 转成 shell 参数，调用既有安装器并传入当前普通用户 UID。继续使用 root-owned 快照、源包及嵌套签名校验、用户归属检查、网络恢复 journal 和安装失败回退；未放宽后台调用身份限制。

macOS 的管理员授权机制及命令参数引用方式参考 [Apple TN2065](https://developer.apple.com/library/archive/technotes/tn2065/_index.html)。新版本若需要重新批准构建身份，仍会由系统要求管理员授权；优化的是操作流程，不是永久免密码。

## 本机验收

- Build 19 已安装到既定路径 `/Applications/LumaRoute/LumaRoute.app`，名称保持 LumaRoute。Build 18 旧安装包保存在私有工作目录。
- 用户确认通过应用内入口，在 macOS 弹出的授权框完成了授权；服务快照实际更新为 Build 19，主程序和 helper 哈希与当前应用相同。
- 无需再手动重新检查，界面显示“已准备就绪”，内核和后台服务正常运行。
- 正常退出后重新打开 Build 19，界面直接进入内核就绪；服务授权 metadata 的哈希及修改时间没有变化，没有重复安装。
- 数据库、原订阅 YAML、Selector 节点选择、系统代理输出与修改前一致。
- 实际开启系统代理后，HTTP / HTTPS / SOCKS 均指向 19790，经代理的真实 HTTPS 请求返回 HTTP 204；随后恢复系统代理及 TUN 均关闭。
- `LumaRouteCLI verify`：74 项原生回归通过；新增 8 项覆盖安装状态分类、身份校验优先级、无效 UID 拒绝、含空格/引号/中文路径的 AppleScript 编译和密码不进入授权命令。
- Release 构建、安装包深度严格签名及 shell 语法校验通过。当前 CLT 不含 XCTest，未宣称 XCTest 全量通过。

本次实际验证了已有服务从旧构建更新和同版本重开。完全未安装服务的首次授权、实际取消系统授权以及 TUN 开启状态下重新同步，尚未做完整运行验收。

本地证据：`work/service-setup-2026-10-15/` 的 `build.log`、`native-tests.log`、`before.json`、`after-authorization.json`、`installation-stamp.json` 和 `final-verification.json`。私有数据与旧应用包不提交到 Git。
