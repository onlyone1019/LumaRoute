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

## 2026-10-27：隔离后台服务注册并迁移旧安装

此前系统管理的 `SMAppService` 与本机安装器共用 `app.lumaroute.helper`，macOS 缓存的包内 `BundleProgram` 注册可以与 `/Library/LaunchDaemons` 下绝对路径的服务冲突。现场表现为后台任务反复 `spawn failed`，内核未就绪；仅执行 `bootstrap` 成功不能证明进程正常运行。

- 系统管理的服务继续使用 `app.lumaroute.helper`；本机 LaunchDaemon 的 Label 与 MachServices 改为独立的 `app.lumaroute.local-helper`。客户端与 Helper 根据安装方式选择一致的端点，旧系统注册即使残留也不能替换新服务或占用它的端点。
- 安装记录保存 `serviceID`。缺少该字段、仍使用旧标识或出现未知标识时，通过现有“完成更新”入口迁移，不能直接标记为已就绪。正常启动使用本机服务时不创建 `SMAppService` 对象。
- 有可用开发者签名的构建在应用内迁移时，先使用 [SMAppService 的注销接口](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister(completionhandler:))清理旧系统注册，再执行管理员安装。已经注销的缺失任务允许重试，其他错误保留并中止安装。ad-hoc 本地签名构建不调用该注销接口：实机验证发现它会被 macOS 以 `Requestor lacks required entitlement` 拒绝；本地构建通过管理员安装器迁移已归属的旧任务，独立名称避免缓存的系统注册抢占新服务。
- 安装器只迁移 root 拥有、Program 指向本机快照的旧 plist。先确认网络 journal 已恢复，保存回退状态，等待旧进程退出，再替换文件；新进程路径、PID 和运行状态连续两次检查通过后才移除旧启动定义。写入、加载或启动失败会回退；回退受阻时保留恢复文件并报告目录。
- 原有 `.command` 安装与卸载入口继续使用同一安装器。命令行安装不会越权注销没有本机 plist 归属的系统注册，但使用的独立名称不会与它冲突。
- 安装后状态检查若遇到后台服务尚在恢复，可复用 XPC 连接重试。不能在每次重试前主动断开连接，否则 Helper 的断连清理会与新状态/启动请求竞争，导致“后台服务正在处理上一项操作”。签名或安装记录变化仍由 HelperClient 负责使旧连接失效。

源码验证：应用、Helper、CLI 的 Swift 6 Debug 构建通过，目标最低系统为 macOS 14；104 项 Swift 测试及 13 项安装/注册脚本测试通过。安装器测试执行生产脚本，使用隔离文件目录和 launchd 替身，覆盖首次安装、旧版本迁移、重复更新、旧 SM 注册残留、持久化 plist 重新加载、加载/启动/写入失败回退、网络 journal 阻止迁移及外部 plist 保护。旧安装器在同一冲突测试中失败，新安装器通过。

上述源码验证阶段未替换已安装应用，也未重新授权真实后台服务。随后的安装验收见下节；隔离重载测试不代表整机重启验收。临时测试产物和编译缓存按项目约定清理，测试脚本保留在仓库。

### 本机安装与服务迁移验收

2026-10-27 按用户授权，将修订后的 0.1.11 / Build 41 本地 Release 安装到 `/Applications/LumaRoute.app`，通过应用内“完成更新”和 macOS 管理员授权完成真实后台服务迁移。该修订未发布 GitHub；安装包目录为 `dist/local-service-migration-20261027/`，文件名包含 `service-migration-20261027`，用于区分同版本号的既有公开包。

- `app.lumaroute.local-helper` 以独立 LaunchDaemon 运行，使用 root-owned 应用快照的绝对程序路径。旧 `app.lumaroute.helper` 任务和系统 plist 均已移除；安装记录包含新的 `serviceID`，应用、快照和构建产物的主程序、Helper、安装脚本摘要一致。
- 首次迁移后自动重连成功，界面显示“内核已就绪”“内核可访问”和后台服务运行中。认证控制接口返回 Mihomo v1.19.32，加载 43 个代理条目及 10 个组；经 `127.0.0.1:19790` 的真实 HTTPS 请求返回 HTTP 204。
- 正常退出并重新打开应用，无需再次管理员授权即可恢复内核；服务授权记录内容和修改时间均未变化，再次代理请求返回 HTTP 204。
- Clash Verge 始终保持运行，系统代理配置与安装前完全相同，仍使用 7890；LumaRoute 的系统代理与 TUN 均保持关闭。SQLite 完整性检查通过，订阅元数据和内容、规则、策略、节点选择及密钥表摘要与安装前一致。
- 最终 Apple Silicon / Intel Release 均通过架构、SDK 与严格嵌套签名校验。两架构 CLI 各通过 218 项断言；Intel 在 Rosetta 下执行，未在 Intel 真机安装。14 项服务安装、注册及自动重连测试通过，新增两种实机失败都在回归中先复现失败再验证修复。

最终本地交付包括双架构 ZIP/DMG、SHA-256 校验清单、实际工作区源码快照与必要上游源码。未进行整机重启、Developer ID 公证或线上发布。临时应用备份、下载/解包副本、测试数据和编译缓存在验收完成后清理。
