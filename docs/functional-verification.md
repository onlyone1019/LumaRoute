# 功能验证记录

当前结论（2026-10-14）：已达到本机日常试用。最新测试为44项原生回归、41项真实内核集成、16项内核维护事务、11项GEO集成；最后收尾与剩余验收见本文末节，较早章节保留当时测试数量和历史状态。

2026-10-13，使用随应用打包的 Mihomo v1.19.32。内核集成使用独立的 19890 / 19891、生命周期使用 19892 / 19893 端口和回环测试服务器，不修改系统代理或 TUN。

## 原生回归：32 项通过

`LumaRouteCLI verify` 验证配置归属、DNS 保留、分组顺序与引用、自动候选、日本过滤、空候选拒绝、兼容已有数据库、凭据脱敏、本地备份和配置事务。

事务验证实际将测试数据库文件设为不可修改，使配置文件已写入后数据库保存失败，再检查原配置、原元数据和事务日志恢复；测试结束解除测试文件标记。不触及用户的真实数据库。

## 真实内核集成：27 项通过

`LumaRouteCLI fixture-check` 覆盖：

- 下载、额度和更新周期解析。
- 自动最低延迟、候选顺序、节点延迟差、不可用节点。
- 手动固定、恢复自动；当前节点断线切换、恢复后重新选择。
- 规则 / 全局 / 直连三种模式的实际请求路径。
- 配置应用失败后的实际路由恢复，无效订阅拒绝。
- Fallback 故障转移。
- HTTP provider 专用测速；配置重建复制同一 provider 的有效缓存，上游无效时实际请求仍通过缓存节点。
- Base64 URI 由内核原生解析并代理实际请求。
- 没有有效节点的 provider 拒绝提交，恢复旧配置。
- 隔离内核正常退出。

URLTest 选择缓存最长约 10 秒，测试通过健康检查与实际请求观察切换，等待窗口覆盖该缓存周期。

## 异常退出与进程归属：7 项通过

`LumaRouteCLI lifecycle-check` 实际启动独立子应用及内核，强制结束子应用，再由新实例清理带有匹配 UID、执行路径和启动时间的孤立内核。验证重复目录锁、端口占用保护、正常退出清理，以及 PID 复用时不向无关进程发送信号。

原生应用中另一次终止自己的内核，日志在约 4 秒内记录恢复，本机内核回到就绪；网络接管保持关闭，原系统代理仍为 7890。睡眠唤醒与切换网卡监听已实现，实际睡眠和换网仍未验收。

网络恢复回归验证当前已提交值、提交前值、其他软件覆盖值三种归属判断。后台服务增加恢复日志、内核退出监测、恢复重试和 launchd KeepAlive；这些 root 路径仍待授权实测。

## 真实订阅原生界面

- 国外流量组设为最低延迟并限定日本后，原来的 26 个候选变为 3 个东京节点，其余 8 组与引用保留。
- 手动固定节点后显示恢复自动入口；清除固定后入口消失。
- 显式通过 LumaRoute 19790 发起 HTTPS 请求返回 204。
- 原生订阅页实际更新成功，额度与更新时间刷新；日本自动覆盖仍保留。
- 全局模式显示 GLOBAL 卡片，原生选择东京节点后的显式 HTTPS 请求返回 204，随后恢复 GLOBAL 的 DIRECT 与规则模式。⌘N 打开真实导入窗口。
- 验证后恢复“保持订阅策略”，该组重新成为 Selector / 26 个候选；本地覆盖为空，事务日志无残留。

## 复现

在仓库根目录运行：

```sh
./script/build_and_run.sh --build-only
.build/debug/LumaRouteCLI verify
```

另一终端启动受控回环服务器：

```sh
python3 script/local_fixture.py
```

然后执行：

```sh
.build/debug/LumaRouteCLI fixture-check Resources/Core/mihomo-arm64 work/functional-core
```

Intel Mac 将内核路径改为 `Resources/Core/mihomo-x86_64`。测试服务器拒绝外部 CONNECT，只响应已知回环目标。

## 未完成的验收

后台服务启动、实际 TUN / 系统代理接管和恢复、睡眠 / 网络切换恢复、内核更新及完整七页验收仍需继续。当前 CLT 不含 XCTest；上述原生回归和真实内核集成结果不等于 XCTest 全量通过。

## 管理员服务实测遇到的签名限制

用户已明确授权安装与临时接管测试。SMAppService 注册并获得批准后，launchd 启动被 AMFI 拒绝：`AppleMobileFileIntegrityError -423: The file is adhoc signed or signed by an unknown certificate chain`，退出原因 `OS_REASON_CODESIGNING`。本机 `security find-identity -p codesigning -v` 返回 0 个可用身份。后台 daemon 明确配置 `UserName=root`，应用在注册前检查签名 TeamIdentifier，并提供可操作的签名提示。

此次未成功启动 root helper，未开启 TUN 或设置系统代理。原 7890 代理在注册前后字节比较一致。失败的服务注册已清理，launchctl确认服务不存在；这是旧 SMAppService 路径的结论；独立本机 launchd 路径的后续无证书实测见下方最新记录。

## 普通内核维护：12 项真实集成通过

`LumaRouteCLI maintenance-check` 使用从官方稳定版发布页下载的真实压缩包和发布资产 SHA256，在隔离端口 19894 / 19895 验证稳定版与架构选择、第三方下载来源拒绝、损坏压缩包拒绝、真实解压、候选启动版本、切换前后的实际代理请求、回退内置版本、已下载文件篡改检测，以及未完成切换事务的重开恢复。内核保存在应用支持目录的独立版本目录，不修改签名应用包。

原生“更新与备份”页实际查询官方发布成功，显示 v1.19.32；与运行版本相同时下载按钮禁用。当前没有比打包版本新的官方稳定版，原生界面里的新版本切换仍需后续发布或专门受控配置进一步验收。普通内核与管理员服务的版本同步、GEO 数据更新回退仍未完成，不把此 12 项测试视为维护需求全量完成。

复现（需要已有官方压缩包和 GitHub release JSON）：

```sh
.build/debug/LumaRouteCLI maintenance-check work/latest-release.json work/official-core.gz Resources/Core/mihomo-arm64 work/maintenance-core
```

## 2026-10-13 本机自用路径与原生界面续作

用户明确保留 SwiftUI、不迁移 Tauri；本机自用不购买开发者账号、不配置证书、不做公证。构建仍自动执行免费的 ad-hoc 签名。

独立 system launchd 安装路径已取得真实证据：管理员安装 root-owned 的应用快照，plist 使用绝对 Program，主应用与 helper 均为 ad-hoc、没有 TeamIdentifier。第一阶段健康服务实际以 UID 0 运行，真实 GUI 请求得到 UID 0 / 协议 1 响应。相同应用标识、不同代码的测试进程调用被拒绝；原 GUI 健康请求通过。旧 SMAppService 路径的签名失败不再是本机自用的固定前提。

随后安装的网络服务实际启动 root Mihomo，系统代理指向 19790，显式 HTTPS 请求返回 204；临时 GLOBAL 选择东京节点后实际 HTTPS 也返回 204，测试后恢复 GLOBAL / 模式。原生关闭接管第一次遇到端口占用，并回退到之前的接管状态；不能把那次关闭算作成功。通过正常退出应用，旧 root 内核退出，原 7890 系统代理与接管前快照字节一致。

对此补上：停止内核后等待强制终止结果、保留未确认退出的进程记录、切换前取消旧控制流、在不同后台间回放 Selector 与自动组固定状态。独立真实内核集成增加 7 项，38 项通过，包括后台切换保留选择与实际请求路径、清除残留固定、有控制流时退出和原端口立即重启。43 项原生回归通过，新增精确 ad-hoc 身份正负例和管理员配置边界。

退出的另一处实测问题是 SIGTERM 触发 AppKit 嵌套退出循环，及错误 sheet 打开时退出请求未完成。改为先异步清理，再进入立即退出路径；普通 GUI SIGTERM 在约 0.12 秒退出，最终错误 sheet 打开时的 SIGTERM 在约 0.43 秒退出，自己的内核无残留、已有系统代理未改变。记录：`work/native-exit-verification.log`、`work/native-exit-with-alert-verification.log`。

界面已经更新公共窗口、侧栏、字号、卡片、主按钮、概览流量图刻度与面积填充，并调整代理组密度和设置菜单宽度。当前截图在 `work/ui-review-2026-10-13/`；没有据此宣布七页视觉验收全部完成。

最终修复构建仍需更新本机服务快照并复测实际关闭接管。TUN、DNS/路由恢复、root 异常退出及睡眠/换网仍未完成。本节不把健康服务、编译成功或非 root 集成通过视为这些验收的替代。


## 2026-10-13 实际后台切换与 TUN 证据

先前仅等待旧进程退出仍未修复 root→用户端口转移：真实 GUI 关闭两次报 19791 占用，退出后普通用户 SO_REUSEADDR bind 返回 errno48、connect 返回 errno61，netstat 保留 root TCP 收尾记录。苹果 XNU in_pcb.c 对非 root、不同 socket UID 的绑定作冲突检查：[源码](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/in_pcb.c)。同 UID 的 38 项隔离集成不能证明跨 UID 转移。失败记录 `work/native-root-to-user-failure.log`。

完整后台服务安装后现统一由服务管理内核，关闭系统代理/TUN 仅重新配置同一后台并恢复网络。实际系统代理 ON→OFF 成功：HTTP 204、东京3保留、PID87088不变，原7890代理字节一致（`work/native-stable-off-result.log`）。未安装完整服务时仍允许普通内核运行。维护和卸载路径已同步适配，root维护界面完整验收待继续。

TUN-only 真实测试：控制接口记录本次 curl sourcePort19898、type Tun、东京3→国外流量→其他流量代理链且已有下载；不指定代理的 HTTPS 请求完整返回200/160000字节、exit0（`work/native-stable-tun-proof.json`）。第一次较大限速请求收到200但超时exit28，未把它作为完成下载证明；使用更小有界请求补测成功。关闭后Tun=false、东京3保留，系统代理原快照一致，3个网络服务DNS配置一致，自己的utun6路由无残留，默认及分段默认路由一致（`work/native-stable-tun-off-result.log`）。

组合模式发现另一个失败：刷新可能跨越配置切换，在应用新配置时调用status/读取旧观察结果，触发错误恢复，3秒后自动关闭接管并重启内核。恢复后代理地址/端口是原7890，但scutil字典多两个默认字段，未宣称此次字节相同。加配置版本与刷新串行保护，错误日志补充实际原因；新构建真实组合启停仍待安装后复测（`work/native-combined-mode-failure.log`）。

43项原生回归及38项真实集成在后台策略变更构建上再次通过。七个页面实际截图已生成并保存为 `work/ui-review-2026-10-13/seven-page-contact-sheet.png`，已读回检查；并不代表全部UI操作验收完成。


## 最终已授权构建复测与共存限制

配置版本保护的新构建编译、严格签名校验、43项原生回归通过（`work/run-refresh-revision-fix.log`、`work/regression-final-local-use.log`）。实际重开由完整后台服务启动内核，接管默认关闭，没有 root→用户端口冲突。

组合模式再次失败时，新增错误日志明确原因为“其他软件已覆盖系统网络设置”，而不是先前未证实的刷新竞态。系统代理被改回7890，所有权保护停止接管并保留外部修改。Clash Verge 同时运行，但没有证据直接定位具体写入进程。配置版本/刷新保护仍保留，用于防止切换期间的旧观察修改新状态；不把它声称为这次外部覆盖的修复。

按 TUN→稳定12秒→系统代理顺序开启，组合模式在12次每秒观察中保持 Tun=true、系统代理19790、同一root PID89052、东京3选择。随后不显式使用代理的请求被自己的控制接口记录为Tun，sourcePort19901、东京代理链、已有下载，完整HTTP200/160000字节/exit0（`work/native-final-combined-proof.json`）。观察间隔1秒不等于定时刷新次数。

点击暂停同时关闭两种模式，Tun=false、选择保留、同一后台内核存活，系统代理与此轮测试前快照字节一致，3个服务DNS与最初快照一致，utun6路由无残留（`work/native-final-combined-off-result.log`）。最早7890快照和后来的快照存在两个默认字段差异，不能宣称所有阶段的字典一直字节相同。

TUN开启时正常CmdQ退出，GUI和自己的root内核均在进程清单中消失，7890代理和DNS恢复、utun6路由消失，原Clash core PID66137仍在（`work/native-final-tun-quit-result.log`）。普通用户对root进程kill-0可能返回EPERM，不能拿失败返回值证明进程退出；最终使用ps清单独立核实。再次打开同一批准构建，root内核就绪、东京3保留、两种接管关闭、代理/DNS未改变，GUI XPC健康检查通过（`work/native-final-relaunch-result.log`）。

当前可本机试用；睡眠/实际换网、崩溃与卸载恢复、管理员维护、其余页面操作全量验收仍未完成。保持SwiftUI，不迁移Tauri，无付费证书或公证要求。


## 2026-10-13 至 14 原生页面操作验收

本轮保持已有批准构建，不改应用二进制、不重新安装管理员服务。仅扩展 `script/local_fixture.py` 的慢响应订阅和请求计数用于真实 UI 验收。测试前将用户元数据和系统代理保存到私有 `work/ui-functional-2026-10-13/`；真实订阅地址和凭据未输出，所有主动新增订阅都指向本机测试服务器。

- 多配置：从添加订阅界面导入本机 HTTP 订阅，保留原订阅并实际激活第二配置；控制接口和真实代理请求证明运行配置已切换。原生文件选择器导入 YAML 成功；URI 订阅也实际导入。文件选择器导入与拖放分别验收。随后用户实际从 Finder 拖入693字节的测试 YAML，原生页新增本地配置并识别3节点，保存内容与源文件一致；原活动订阅和网络设置保持不变，测试配置已从原生页面删除。证据为 `drag-import-result.json`。
- 更新失败：服务端返回无效 HTML，原生更新报错且卡片显示保留旧配置；源文件 SHA256 不变、活动配置不变、真实代理请求仍成功。恢复有效响应后，更新时间更新且错误清除。
- 定时更新：应用关闭时只把测试订阅的到期时间置为过去，重新启动后不点击更新，后台任务实际触发。失败保持旧文件、记录 lastAttempt，连续四次每秒观察不重复请求；随后有效响应到期更新成功并清除错误，真实订阅元数据完全不变。证据为 `scheduled-failure-result.json`、`scheduled-success-result.json` 和 `scheduled-failure.png`。
- 测速：五个受控 HTTP 节点延迟约三秒，配置并发一。原生开始、停止后保持“已停止3/5”，服务端只启动四个请求、后续五秒不再开始剩余候选；完成中的旧请求不回写进度。重启批量测试完成5/5、五个真实延迟约3秒、观测并发峰值一。单节点七秒响应超过五秒超时，内核记录0延迟，页面显示“失败/不可用”。证据为 `latency-cancel-result.json`、`latency-completed-result.json`、`latency-timeout-result.json`。
- 规则：原生编辑域名后缀REJECT，同一fixture域名禁用时实际返回Tokyo、启用时HTTP502；新增两条相同IPv4网段规则，DIRECT在前返回本机direct，REJECT移到前面后同目标阻断。无效CIDR被内核校验拒绝，保存和运行规则未变化；撤销、搜索正常。订阅更新后，自定义三条规则及顺序仍是内核最前面的规则。证据为 `rules-valid.json`、`rules-result.json`。
- 日志：暂停时固定16条，后台产生两条真实请求日志，继续后显示18条；错误级别过滤5条、关键词过滤1条、详情显示完整错误。错误+内核来源组合过滤为0条，恢复来源后重新显示5条。原生导出的文件包含完整18条日志（不限当前过滤），合成token被替换为“已隐藏”，原值不存在；清空后列表和详情为空。证据为 `diagnostics-verified.txt`、`logs-result.json`。
- Mac行为：Command-N打开添加订阅；关闭主窗口后GUI/内核继续运行，用户从菜单栏打开主窗口后，窗口可操作且两者PID完全相同。深色、浅色实际应用并保存截图，恢复跟随系统。登录启动通过SMAppService注册，系统BTM中存在enabled/allowed主应用记录，注销后已知主应用记录均disabled；未注销真实会话验证下一次登录。Command-Shift-P实际开启19790系统代理，第二次恢复原7890快照。证据为 `closed-window-processes.json`、`appearance-dark.png`、`appearance-light.png`、`login-enabled-registry.txt`、`login-disabled-registry.txt`、`mac-integration-result.json`。

所有测试规则和四个测试配置均通过原生页面删除，删除产生的本机备份保留。恢复原订阅、东京3和临时测速设置后，整个持久化数据库与测试前逐项相同。测试前持久化TUN记录是true、connectOnLaunch=false；恢复这个原始记录后再次启动，实际TUN/系统代理保持关闭。随后外观与登录注册验证再次写设置；结束这批验收后正常退出，已再次核对并恢复整个数据库与原始记录一致，测试版本历史已清除，原Clash PID66137仍在，系统代理快照相同（`cleanup-final-result.json`）。

改动后的本机fixture再次通过现有38项真实内核集成（`core-regression.log`）。登录会话启动、实际睡眠/换网及完整异常恢复仍需继续，不能把这些页面操作当作全量完成。管理员维护与备份的后续实测见下节。


## 2026-10-14 管理员维护、备份和连接验收

保持网络接管关闭，在原生设置执行GEO更新和回退。实际root内核PID93081→95501→95588，v1.19.32与东京3选择保留；每次变更后显式代理HTTPS返回204/exit0，TUN=false、系统代理等于7890测试前快照、原订阅与活动配置不变。证据为 `geo-update-root.json`、`geo-rollback-root.json`。同一真实GEO实现的11项隔离集成再次通过，包括损坏数据拒绝、失败后文件和流量恢复、有效更新回退、三份原数据字节一致及未完成事务恢复（`geo-regression.log`）。未使用普通用户无法读取的root文件作为外部字节核对证明。

原生创建本地备份后，数据库与当前状态一致、所有订阅文件内容相同。临时并发6→7并保存，再从原生文件夹选择器恢复该备份，持久化并发回到6，完整数据库和文件与备份一致；自动创建恢复前备份，其中保留并发7。复制备份到私有测试目录并破坏YAML，再通过同一路径恢复，原生明确报错，数据库和源文件不变、东京节点的真实代理请求继续返回204。证据为 `backup-created.json`、`backup-restored.json`、`backup-invalid-result.json`、`backup-restore-root.json`、`backup-invalid-root.json`。备份凭据仍在本机钥匙串，不输出真实订阅内容。

连接页使用两条本机流式HTTP请求（源端口23901/23902），真实显示curl路径、目标、IPCIDR规则、DIRECT链和递增流量。进程搜索2、UDP过滤0、TCP过滤2、不匹配关键词0、目标IP搜索2、DIRECT策略2。原生详情关闭23901后控制接口仅余23902，原生关闭全部后控制接口0；两个curl均因传输被关闭退出18，未把自然完成当作断开证据。证据为 `connections-before-close.json`、`connections-after-single.json`、`connections-after-all.json`、`connections-result.json`。

管理员内核切换实测最初失败：以已校验的官方v1.19.31构造一次性回退历史后，原生“回退上次内核”报“新内核版本与官方发布信息不一致”。失败恢复原v1.19.32、原东京3和系统代理（`core-rollback-31-failure.json`）。定位到客户端在beginSwitch之后、finishSwitch之前仍使用已提交selection.active构造服务请求，候选尚在pending-switch中。增加activationVersion读取事务候选，并保留显式nil代表内置版本。新增真实维护事务断言先稳定失败（`core-version-red.log`），修复后16项维护集成通过（`core-version-fixed.log`），43项原生回归通过（`native-regression-version-fixed.log`），新.app构建和严格签名验证通过（`core-version-fixed-build.log`）。用户同步服务后，新服务快照与修复GUI/helper摘要一致。原生回退到官方v1.19.31成功，随后检查更新、下载并切换到v1.19.32，再回退v1.19.31；三次独立控制接口确认实际版本，ps确认UID0和各自下载目录，每次显式代理HTTPS204/exit0、东京3保留、TUN关闭、原7890系统代理不变。证据为 `core-fixed-rollback31.json`、`core-fixed-update32.json`、`core-fixed-postupdate-rollback31.json`。退出后清除一次性测试历史，重开回到根快照中的内置v1.19.32；完整用户数据库仍与原始快照相同（`core-fixed-final-bundled.json`）。候选文件由官方发布摘要校验，root服务独立下载，不接受用户提供可执行文件路径。

当时发现两处错误文案问题：规则验证失败展示过多内核启动日志，损坏YAML备份显示Yams内部错误。后续均已修复并从原生入口复测，证据见本文末节。


## 2026-10-14 TUN开启时应用异常退出恢复

修复并授权的构建开启TUN、系统代理保持关闭。不指定任何代理的有界HTTPS下载返回200/160000字节/exit0，自己的控制接口记录sourcePort23905、东京3代理链和下载165635字节。SIGKILL前该请求已完成，不能声称测试了下载中断；这条记录未保存接入type，未把它替代此前保留type=Tun的完整接管证据。

仅对当前UID501、路径精确匹配的GUI PID30469发送SIGKILL，不向root进程或其他应用发信号。后台XPC断开处理在约半秒内清理自己的root内核，ps独立确认GUI和own core均消失。原代理与测试前字节一致，3个网络服务DNS逐项相同，自己的utun6路由消失，default/分段默认路由恢复，原Clash PID66137保持存在。证据为 `crash-before.json`、`crash-tun-on.json`、`crash-after.json`、`crash-recovery-result.json`、`crash-tun-curl.log`。重开同一构建，后台内核与真实代理请求正常，东京3保留，TUN/系统代理均关闭（`crash-relaunch.json`）。这次验证的是GUI异常退出，不是root内核或服务本身崩溃。


## 2026-10-14 实际睡眠唤醒

用户实际选择睡眠并唤醒。pmset记录08:49:16进入Software Sleep、13秒后08:49:29从Deep Idle唤醒；原生日志08:49:32记录“已重新检查网络与内核连接”。GUI PID30853和root core PID30857保持不变，原订阅、东京3和完整持久化数据库不变，显式代理HTTPS204/exit0、原7890系统代理和3个服务DNS不变。证据为 `sleep-system-events.txt`、`sleep-before.json`、`sleep-after-network.json`、`sleep-after.json`、`sleep-recovery-result.json`。

本次睡眠时系统代理/TUN均关闭，不将它作为TUN开启睡眠恢复的证明。用户选择实际断网重连“稍后测”，此次不更改物理网络，也不把模拟NWPath事件作为替代。


## 2026-10-14 最终试用状态与剩余验收

本节证据目录为 `work/design-qa-2026-10-14/`。最终构建严格签名校验通过，已安装服务与GUI/helper摘要一致（`service-snapshot-final-match.json`）。44项原生回归与39项真实内核集成通过（`native-regression-final.log`、`core-regression-final.log`）；16项内核维护事务、11项GEO集成见上一证据目录。未使用完整Xcode XCTest环境，不把这些计为XCTest。

在Mixed既有流量证据之外，System/MTU1280、gVisor/MTU1500、MIPS/MTU9000分别实际接管IPv4请求，自己的控制接口记录type=Tun、东京代理链与流量，完整HTTP200/160000字节/exit0（`tun-system-result.json`、`tun-gvisor-result.json`、`tun-mips-result.json`）。自动路由、自动接口探测、局域网排除及DNS劫持配置已核对。每次关闭后原7890代理、3个服务DNS和IPv4默认路由恢复。MIPS测试启用IPv6参数，其关闭后的IPv6默认路由也恢复，没有自己的utun IPv4/IPv6路由残留（`mips-off-restoration.json`）；请求明确使用IPv4，不作为IPv6出口证明。

系统代理原生开启后HTTP/HTTPS/SOCKS均使用19790，六条绕过地址与保存设置相同；关闭后与原7890代理快照一致（`system-proxy-bypass-result.json`）。其他代理应用覆盖时的所有权保护已验证；仍应避免两个应用同时反复争用系统代理。

本应用root内核异常退出验收：仅SIGKILL精确匹配的本应用root内核67172，GUI67128保持不变，3.69秒后恢复root内核67202；真实HTTPS204/exit0、节点和代理不变，原Clash进程66137保留（`root-core-recovery-result.json`）。本次接管关闭，不代替TUN开启下的内核崩溃或helper服务自身崩溃测试。

七页最终实机与源图比较记录见项目根目录 `design-qa.md`，截图见 `final/`。订阅来源筛选、管理备份直达、损坏YAML可读错误、规则校验精简原因、有效恢复成功提示均从原生入口复测（`native-polish-results.json`、`final/08-invalid-backup.png`、`final/09-invalid-rule.png`）；真实连接的DIRECT策略与本地时间完整可读，连接实际关闭。

最终正常退出后，仅恢复原持久化TUN偏好；完整数据库与验收前快照逐项相同，connectOnLaunch仍为false。测试fixture PID91674确认归属本项目后停止，测试配置/规则/连接已清理，应用生成的恢复备份保留。重开同一构建后实际系统代理/TUN均关闭，内核v1.19.32运行，东京3保留，真实代理HTTPS204/exit0、原7890代理快照不变（`final-cleanup.json`、`../ui-functional-2026-10-13/final-clean-relaunch.json`）。

当前仍未完成的验收：实际登录后自动启动；用户明确延后的物理断网重连；TUN开启的实际睡眠唤醒；IPv6出口；helper服务自身异常及完整卸载/重装恢复。已具备本机日常试用条件，尚不能宣称全部边界验收完成或对外发布质量。


## 2026-10-14 服务生命周期与TUN开启异常恢复

证据目录 `work/service-lifecycle-2026-10-14/`。第一次真实helper崩溃后5.36秒恢复，随后正常退出GUI并卸载却失败；第二次捕获确切错误“服务尚未退出，保留文件。”（`service-lifecycle-reproduced-failure.json`）。此时launchd稍后已无job，但安装文件仍在，原网络不变。诊断性卸载重装一次成功，未用它掩盖原序列失败。

定位为bootout返回后launchd仍短暂展示退出中job，卸载器立即检查造成误报。`script/install_local_service.sh`增加最长35秒等待，服务退出未确认时保留文件；卸载及更新替换快照前均调用同一等待，不放宽身份、所有权或网络journal保护。修复版通过bash语法检查与规范构建/严格签名（`build-service-wait.log`），已同步管理员服务。

原始失败序列在修复版完整复测通过（`service-lifecycle-result.json`）：GUI78843保持，helper78579强制退出后4.76秒变为78922、root内核变为78943；显式HTTPS204。正常退出GUI后实际卸载，job、安装清单、root应用快照和自己的进程均不存在；完整用户数据库除运行恢复会清零的TUN偏好外相同，订阅文件SHA256逐项相同，原代理/三个服务DNS及原Clash保持。重装同一构建并从.app重开，root helper79083/core79131、原节点链和真实HTTPS204均正常。root安装凭据只在用户Terminal使用，测试脚本由普通用户运行，信号仅作用于立即复核路径/UID的自有PID。

额外验证TUN开启下崩溃恢复。崩溃前实际出现utun6且DNS改变，系统代理仍为原7890。仅结束本应用helper79083，GUI79124不变，3.41秒恢复helper80048/core80067；仅结束本应用root core80067，helper80048与GUI均不变，3.56秒恢复core81017。两次均检查3个服务DNS、原代理、IPv4/IPv6默认路由相同，无自己的utun路由残留，接管关闭、原东京节点链及原Clash保留，恢复后实际HTTPS204（`service-tun-crash-result.json`、`core-tun-crash-result.json`）。结合此前GUI在TUN开启时崩溃恢复，三个进程层的异常恢复均已实测。

当前ifconfig未发现公网IPv6地址（`ipv6-environment.json`）；IPv6参数应用和路由恢复已验证，但公网IPv6出口仍缺少环境，不能宣称通过。实际断网仍由用户明确延后，TUN开启实际睡眠唤醒的后续结果见下节。


## 2026-10-14 TUN开启的实际睡眠唤醒通过

用户选择现在验收并手动睡眠/唤醒。系统pmset证据确认11:02:34进入Software Sleep，11:02:39从Deep Idle唤醒，实际睡眠5秒（`work/service-lifecycle-2026-10-14/sleep-tun-system-events.txt`）。本次不是模拟通知，也不把期望约10秒写成实际睡眠时长。

GUI79124/helper80048/root core81017在睡眠前后不变，TUN保持Mixed/MTU1500开启，节点链与持久化数据库相同。唤醒前24631、唤醒后24632两个未显式设置代理的IPv4请求，自己的控制接口均记录type=Tun、东京3链及实际下载，完整HTTP200/160000字节/exit0。唤醒后主动关闭TUN，3个服务DNS、原7890代理及IPv4/IPv6默认路由恢复，无自己的utun6路由残留，原Clash66137保持（`sleep-tun-result.json`及四份sleep-tun-*.json快照）。

随后正常退出，恢复验收前唯一变动的持久化TUN偏好（原true，connectOnLaunch=false），完整数据库与最初快照逐项相同。GUI/helper/安装器与管理员快照SHA256一致，两份.app严格签名校验通过（`final-cleanup.json`）。重新打开仍默认关闭接管，实际状态另见收尾重开证据。

目前剩余人工/环境验收为真实登录后自动启动、用户明确延后的物理断网重连，以及有公网IPv6的网络中的实际IPv6出口。它们尚未验证，不把本次睡眠通过扩大为这些场景已通过。


最终重开证据：`work/ui-functional-2026-10-13/service-lifecycle-final-relaunch.json`，实际root内核81589、v1.19.32，东京3与原分组链保留，TUN关闭、原7890代理快照一致，显式HTTPS204/exit0；重开后的完整持久化数据库仍与原始快照逐项相同。用户明确选择“稍后再测登录自启”，该设置保持原值；物理重连也仍按先前选择延后。


## 2026-10-14 IPv4网络下真实IPv6 TUN出口通过

本节证据目录为 `work/ipv6-acceptance-2026-10-14/`，取代前文“没有公网IPv6便无法验收代理IPv6”的推断。先通过IPv6字面目标的显式代理请求验证节点具有IPv6出口；IPv6-only目标DNS只有AAAA、服务器返回IPv6地址（仅保存地址族，不保存出口地址）。

首次原生开启IPv6/TUN后，真实路由查询失败，API中global ipv6=true但tun没有inet6-address（`ipv6-route-failure.json`）。最初误判缺少显式TUN地址，添加该地址及对应静态断言后仍无法建立路由（`ipv6-second-route-failure.json`）。这次改动没有解决问题，最终已撤回ConfigComposer显式地址和两条镜像断言，不以46项静态绿灯替代运行验收。

继续读取打包版本的官方源码：v1.19.32 config.go已默认提供fdfe:dcba:9876::1/126，但parseIPV6在verifyIP6失败时清空TUN地址；utils.go提供SKIP_SYSTEM_IPV6_CHECK环境选项。v1.19.31也有同一选项（`upstream-version-compatibility.json`）。CoreRunner在配置校验和真正启动时固定设置该选项，让用户明确的YAML ipv6开关生效；关闭IPv6仍由YAML控制并清除TUN IPv6地址。该选项只控制网络能力推断，不改变系统授权或服务调用身份验证。

真实CoreRunner先以IPv6关闭启动，再热启用IPv6的隔离回归稳定失败（`runtime-red.log`）；修复启动环境后新增启用/关闭两项真实内核断言，加上原39项共41项集成通过（`runtime-green.log`），44项原生回归通过（`native-final.log`）。最终构建及服务已同步（`build-ipv6-runtime-final.log`、`service-sync.json`）。

从原生设置启用IPv6和TUN，实际IPv6目标2606:4700::6810:b9f1路由到utun6，自己的连接sourcePort24642、type=Tun、IPv6目标、curl路径和东京3链均确认；请求HTTP200，服务器返回IPv6出口地址，未使用显式代理且未关闭TLS证书验证（`tun-ipv6-result.json`）。同一配置下IPv4 TUN请求完整HTTP200/160000字节/exit0（`../service-lifecycle-2026-10-14/ipv6-dual-ipv4.json`）。

原生单独关闭IPv6、保持TUN开启后，实际内核IPv6地址清空、自己的IPv6路由消失，IPv4未显式代理请求204/exit0（`ipv6-off-tun-on.json`）。随后关闭TUN，原3个服务DNS、7890代理、IPv4/IPv6默认路由逐项恢复，没有自己的utun路由残留，原节点链与Clash66137保留（`network-restoration.json`）。测试fixture83879确认项目归属后停止；正常退出后完整数据库恢复最初快照，GUI/helper与管理员快照一致，两份.app严格签名验证通过（`final-cleanup.json`）。

目前只剩用户明确延期的真实登录自启与物理断网重连验收。IPv6完成证明限于已测试的Mixed/MTU1500、当前IPv6可用节点的代理出口；不把它扩展为没有原生IPv6链路时可以DIRECT访问公网IPv6。

最终重开 `work/ui-functional-2026-10-13/ipv6-final-relaunch.json` 再次确认v1.19.32、TUN关闭、原节点/活动配置/7890代理不变，实际HTTPS204/exit0；完整持久化数据库与最初快照逐项相同。
