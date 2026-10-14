# 原生 macOS 本机自用后台服务方案

日期：2026-10-13。本文保留原始方案研究；下文的“待验证”描述属于初始方案，实施结果以本节及 functional-verification.md 的最新实测为准。最新方向为继续 SwiftUI，不迁移 Tauri。

## 当前实施结果

独立 system launchd 服务已通过管理员安装，实际以 UID 0 运行。完整 root-owned 应用快照位于 `/Library/Application Support/LumaRoute/service/LumaRoute.app`；无需修改 containingApp() 的包内查找。安装记录绑定用户和具体 ad-hoc 构建，XPC 双向限定代码身份，健康检查与同标识不同代码拒绝已实测。无需购买开发者证书或公证，不关闭系统保护。

完整网络服务已实测系统代理开启/关闭、东京节点保留，以及 TUN-only 实际流量与关闭恢复：自己的控制接口记录 Tun 连接和东京代理链，未显式使用代理的请求完整得到 HTTP 200 / 160000 字节；关闭后 3 个网络服务 DNS 设置与测试前一致，自己的 utun6 路由消失。

root 内核退出后，普通用户立即复用其端口仍被 macOS 拒绝，因此完整服务已安装时统一由服务管理内核，关闭接管不切换运行 UID。补上配置版本检查与禁止重叠刷新，避免切换中的旧观察误触发恢复。组合模式新日志进一步明确实际失败为系统网络设置被覆盖：开启 TUN 后系统代理被改回 7890，所有权保护主动停止接管；本机 Clash Verge 也在运行，不能仅凭共存就断言具体写入者。改为先 TUN 后系统代理，组合模式稳定观察和真实流量通过，暂停恢复通过。TUN 开启时正常退出及重新启动也通过。后续已实测GUI/root内核/helper异常恢复（包括TUN开启时）、服务卸载重装和接管关闭/TUN开启时的真实睡眠唤醒。卸载遇到launchd退出登记竞态已修复并完整复测，详见functional-verification.md最新章节；实际登录与物理换网等剩余人工验收以requirements.json为准。

## 1. 结论与约束

继续使用 SwiftUI + LumaRouteCore + Mihomo。普通界面和内核继续采用构建自动完成的免费 ad-hoc 签名，不购买开发者账号、不配置 Apple 证书、不做公证。已有普通应用能运行不等于 root 服务能运行。

优先验证**管理员明确安装的独立 system launchd daemon**，不继续把 `SMAppService.daemon` 当作无证书自用服务的默认路径。它是待验证候选，不能声称通过手工安装就能绕过所有 macOS 签名/启动检查。后台服务与 TUN 仍须管理员授权；无付费签名不等于无权限边界。

不关闭 SIP、AMFI 或 Gatekeeper，不扩大钥匙串访问权限，不运行整个 GUI 为 root，不把任意命令或可执行文件路径交给特权服务执行。

## 2. 为什么现路径失败，以及证据能证明什么

| 证据 | 能支持的结论 | 不能推出的结论 |
|---|---|---|
| [HelperClient.swift](../Sources/LumaRoute/Support/HelperClient.swift) 检查签名 `TeamIdentifier`，不存在时不注册或发送请求 | 现客户端主动拒绝 ad-hoc 构建使用后台服务 | 删除检查即可正常启动 |
| [服务拒绝日志](../work/helper-signing-rejection.log) 出现 AMFI `-423`，原因包含 ad-hoc / 未知证书链 | 当前 bundle + SMAppService 的 helper 曾被系统实际拒绝 | 每个 launchd 程序都必须购买 Developer ID |
| [功能验证记录](functional-verification.md) 记载服务注册/授权后未启动，网络接管未发生 | TUN 和系统代理 root 路径尚未完成验收 | 服务已授权就等于服务健康 |
| Apple DTS 提醒 SMAppService 下 app/helper 应使用相同 Apple 签名身份，ad-hoc 会有问题 | 当前失败符合这条安装机制已知限制 | legacy daemon 上不存在任何签名限制 |
| 本机 `man launchd.plist`：`BundleProgram` 只适用于 SMAppService 安装；`Program` 为绝对路径 | 不能直接把现包内 plist 复制到 `/Library/LaunchDaemons` 就使用 | 仅替换 plist 键就完成安全迁移 |

官方出处：[Apple DTS 关于 SMAppService 和 ad-hoc](https://developer.apple.com/forums/thread/799910)、[SMAppService 入门](https://developer.apple.com/forums/thread/802443)。启动约束仍可决定 daemon 是否被允许启动，见 [Apple 启动环境约束](https://developer.apple.com/documentation/security/applying-launch-environment-and-library-constraints)。

Apple 文档仍描述由管理员部署的 `/Library/LaunchDaemons` 路径，并提供 legacy plist 状态与关联 app 的兼容机制。这证明独立安装是可研究的正式机制，不证明我们的 ad-hoc helper 在当前 macOS 上已经能启动。[Apple daemon 指南](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)、[旧 helper 升级文档](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)。

## 3. 保留的能力与需要调整的接口

| 现有模块 | 处理方式 |
|---|---|
| `LumaRouteCore`、订阅下载/解析、配置事务、测速和自动策略 | 保留实现；UI 视觉改进不要求换业务核心 |
| `LocalStore`、`Secrets`、用户配置/内核维护 | 保留用户数据目录、订阅 UUID、钥匙串 service/account；不导出订阅凭据 |
| `HelperContract` 的业务操作 DTO | 可保留操作白名单；增加协议版本、安装身份、恢复状态契约，不能增加通用 shell 能力 |
| `HelperController` 的 UID 隔离、恢复 journal、watchdog | 保留业务逻辑，但完整验证启动、退出和更新顺序 |
| `HelperClient` 注册/注销/状态 | 区分“普通模式”“本机安装服务”“现 SMAppService”；本机模式使用自身安装记录和受限健康 RPC，不伪造 SMAppService 状态 |
| helper `containingApp()` | 必须替换：独立可执行文件路径不含 `.app/Contents/`；不能由客户端任意指定 app 根目录 |
| `ClientVerifier` | 保留身份验证，改为安装时固化的受信客户端 requirement；不能简单接受同 UID 或同 bundle ID |
| 内核/GEO 查找 | 特权进程必须使用独立、root 拥有的固定资源；用户程序可继续使用包内资源 |
| 七页 SwiftUI | 先针对概览、代理组、TUN 设置验证与 `design/` 现有设计稿的视觉一致性，再逐页落实；原生技术栈不意味着采用默认表格/表单布局 |

源码依据：[Package.swift](../Package.swift)、[AppStore.swift](../Sources/LumaRoute/Stores/AppStore.swift)、[Helper main](../Sources/LumaRouteHelper/main.swift)、[HelperContract.swift](../Sources/LumaRouteCore/HelperContract.swift)、[CoreRunner.swift](../Sources/LumaRouteCore/CoreRunner.swift)、[Secrets.swift](../Sources/LumaRouteCore/Secrets.swift)。

## 4. 建议的本机安装布局和身份边界

以下路径是待实现建议，尚未创建：

```text
/Applications/LumaRoute.app                            稳定的用户界面安装位置
/Library/LaunchDaemons/app.lumaroute.helper.plist       独立 system job，绝对 Program
/Library/Application Support/LumaRoute/service/
  versions/<version>/LumaRouteHelper                   root 拥有的 helper 副本
  versions/<version>/mihomo                            root 拥有的初始内核
  versions/<version>/GeoData/                          root 拥有的初始数据库
  installation.json                                  UID、受信 requirement、版本、校验摘要
/Library/Application Support/LumaRoute/users/<uid>/    现有 root runtime/journal
~/Library/Application Support/LumaRoute/               现有普通用户数据
```

独立 plist 使用 `Program` 指向固定 root 可执行文件，保留限定的 `MachServices` 和 root 身份；`AssociatedBundleIdentifiers` 只负责系统设置中的关联显示，不能替代客户端认证。首次实验使用单独测试 label，无网络动作和自动重启循环，避免与旧服务冲突。本机 `man launchctl` 确认 `system/` 是特权域，修改需要 root；`bootstrap` / `bootout` 分别加载与移除定义，`print` 只用于人类诊断，输出不是稳定产品 API。

所有 root 可执行文件、plist、安装清单及父目录必须由 root 拥有且不可被普通用户、group/other 修改，拒绝符号链接和路径穿越。不能让 root daemon 执行开发工作树 `dist` 中普通用户可写的 helper/mihomo。安装暂存到同一受控卷、检查完整性后原子切换；旧版本在成功握手前不删除。权限具体值须由实现与测试确定，日志和用户运行目录沿用最小可读写权限。

客户端信任方案：管理员安装时验证选定 app 构建，再把独立取得的 designated requirement / 精确 code hash 和批准 UID 写入 root 清单。ad-hoc 身份没有稳定 Team ID，重编译可能改变 code hash；新版本需要明确更新受信安装身份。普通 GUI 不能调用 RPC 自行重新绑定信任，也不能要求 helper“信任我提供的 requirement”。bundle ID、文件路径、UID、普通共享口令都不足以单独建立 root 授权。

当前 `ClientVerifier` 通过 PID 取动态代码，迁移时应评估使用系统支持的 peer requirement 验证 API，避免 PID 复用竞态。Apple DTS 推荐 `NSXPCConnection.setCodeSigningRequirement` 或 C XPC 的 peer requirement；这两个 API 对精确 ad-hoc requirement 的行为仍需当前 SDK 与本机负面测试确认。若采用 C XPC，`SecCodeCreateWithXPCMessage` 是消息发送者代码校验的官方方向。客户端也应绑定已安装 helper 身份，避免向假服务发控制器 secret。[Apple XPC 身份验证说明](https://developer.apple.com/forums/thread/681053)。

特权服务只接收经过认证的状态、启动、应用配置、停止/恢复、GEO 维护等已知业务动作。现 helper 对 source/request 有大小限制、按实际连接 UID 分区，并自行从官方版本下载 root 内核；继续保留。网络端口、TUN 参数、provider 的路径和 URL 也须校验，避免以 root 读取任意用户指定文件、执行任意脚本或扩展控制器监听范围。配置/YAML 中潜在文件引用不能因“只自己用”而免检。

## 5. 资源路径、钥匙串与更新

现 `CoreRunner.bundledBinary()` 依赖 `Bundle.main/Contents/Resources/mihomo`，并接受 `LUMAROUTE_CORE` 开发覆盖；helper 又从 app 根查找同一资源。独立 daemon 下这两种假设都失效。特权实现需显式注入 root 安装清单验证过的资源位置，并忽略用户环境或客户端可执行路径；普通 app 保留开发覆盖的边界。

用户数据库、订阅文件和钥匙串不需要换结构。保留 `app.lumaroute.desktop` service、`subscription-<UUID>` 和 `controller-secret` account；重新安装/编译的 ad-hoc app 可能再次触发钥匙串授权，必须由用户完成，不能降低 ACL。root helper 不读取登录钥匙串、不持久化完整订阅 URL；GUI 经现有安全通道提供运行需要的信息。

root 内核更新继续使用官方来源、版本、架构、SHA256 与文件所有权验证，不接受用户目录的二进制。helper 和 GUI 更新需作为兼容版本处理：恢复/暂停网络接管、验证并暂存新版本、管理员安装及重绑定身份、握手并核对协议、再允许用户开启接管。失败保留旧版本和恢复 journal；不能留下新 GUI 无法调用旧 helper 恢复网络的状态。

## 6. 分级验证：先证明能启动，再碰网络

| 阶段 | 实验内容 | 必须取得的证据 |
|---|---|---|
| A：无 root 本地验证 | requirement 生成、旧/新 ad-hoc 构建匹配、IPC 协议、超时和错误处理 | 正例匹配；伪造 bundle ID、修改二进制、新构建、错误 UID 均按策略拒绝 |
| B：无网络 root 最小实验 | 管理员安装独立测试 daemon，只提供健康/身份查询，不加载 Mihomo、不改代理/DNS/路由 | root eUID、真实 executable 路径、启动日志、限定 RPC 响应、实际退出与完整移除；只看到 launchctl job 不算通过 |
| C：真实 helper 只读模式 | 安装自己的 helper 和 root 资源，验证认证/状态、升级与回退 | 未信任进程不能调用；升级重新绑定受控；断线/重启不丢恢复状态 |
| D：隔离 root 内核 | 独立端口启动 root Mihomo，TUN/系统代理关闭 | 真实代理请求、版本与资源一致、停止和残留 PID 归属处理正确 |
| E：系统代理短测 | 保存当前网络配置后开启、真实请求、关闭；验证失败及用户外部覆盖 | 所有被接管服务恢复原值；其他软件的新配置被保留；无孤立进程 |
| F：TUN 短测 | 显式授权后启停、DNS、直连/代理、路由、UDP；app/core/helper 异常退出和睡眠换网 | 真正经过 TUN 的请求和流量证据；原代理/DNS/路由恢复；失败可从受控恢复命令清理 |

阶段 B 是最早技术门槛；如果 AMFI 仍拒绝普通 system daemon，保存完整签名、launchd 和 AMFI 证据并清理测试，不把失败转化为“用户必须买证书”。再研究受支持的本机执行方案；不尝试关闭系统保护。本文未执行任何阶段 B–F。

本轮不提供可直接粘贴的 root 安装命令，因为当前 helper 仍要求 app 包路径，身份/资源布局还未适配。后续实施需先生成可审查、幂等的安装/卸载脚本，再由用户在 Terminal 或系统授权界面输入管理员密码；密码不传给代理。不要以旧 plist 直接 `bootstrap` 真服务。

## 7. 安装、卸载与恢复要求

安装流程：读取并展示将安装的版本/UID/固定路径 → 确认旧服务和网络 journal → 暂停接管并恢复网络 → 验证暂存文件、权限及身份 → 管理员安装并加载 → 有限时健康和双向认证 → 成功后登记 active 安装。出现错误按已完成步骤回滚，不自动开启 TUN。

卸载流程：请求真实 helper 停止并恢复 → 独立核对网络恢复 → 移除 system job → 确认进程退出 → 删除本产品已记录的固定服务文件。恢复未完成时保留 journal 和受控恢复工具，不先删除唯一能够恢复网络的服务；不删除用户订阅或钥匙串，除非用户明确要求。

必须补充 SIGTERM 下的受限清理、journal 原子性、恢复重试、应用失联恢复以及更新时的防并发锁。现 helper 已有 watchdog 和断线处理，但这些 root 实际行为未验收；不能仅以代码存在宣布完成。恢复只修改仍属于 LumaRoute 的值，沿用 `SystemNetwork.owns` 原有比较原则，不覆盖用户或 Clash Verge 后来的改动。[SystemNetwork.swift](../Sources/LumaRouteCore/SystemNetwork.swift)。

## 8. 尚未解决的问题和实施顺序

1. 当前 macOS 是否允许这个 root-owned、ad-hoc、独立 system daemon 实际启动？先用无网络实验取得证据。
2. 精确 ad-hoc peer requirement 能否通过公开 NSXPC API完成双向绑定？旧/新构建、恶意同 ID 客户端、修改资源都要测试。
3. 更新 app 时如何以管理员操作同步安装清单和 helper，既保持钥匙串兼容又不扩大信任？
4. 现 root 配置是否允许不安全的外部文件引用，退出/卸载在恢复失败时是否可持续修复？
5. 完整 TUN 与系统代理启停、异常恢复、睡眠/换网仍须真实验收。购买证书不能当作此自用方案的完成门槛。

实施可以并行推进普通 UI 视觉和非特权功能，但服务实验必须按 A→B→C→D→E→F 的依赖顺序。保持七页设计、订阅原有代理组和已测普通功能；不因后台权限暂未验证而把需求缩成一个普通代理壳。
