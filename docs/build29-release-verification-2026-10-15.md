# Build 29 双架构发布验证

日期：2026-10-15。仓库 `onlyone1019/LumaRoute` 保持私有；继续使用开发预览版（pre-release）分发。

## 产物来源

应用代码为 `8fc823f8090d22c1a51c5d3aec19f7c832123f34`，对应 [main 双架构 CI](https://github.com/onlyone1019/LumaRoute/actions/runs/38728284129)。该 CI 的 ARM、Intel 构建、签名与架构检查、单元测试、GEO 离线重建和全历史秘密扫描均通过。发布整理仅更新 README、发布说明与本记录，不修改应用、依赖、构建脚本或资源；发布标签包含这些文档更新。

ARM64 使用刚完成本地安装时生成的 Build 29 文件；Intel 从相同应用源码重新构建，使用独立编译目录。两套应用与 ZIP、只读挂载 DMG 中的应用逐文件核对一致。DMG 镜像和四个应用包均通过严格嵌套签名核验，主程序、后台服务及 Mihomo 三个可执行文件分别匹配目标架构。

两种架构各 218 项原生回归、隔离 Mihomo 冒烟通过。两套包的图标、许可、GEO 文件及架构无关资源一致，当前包均不含旧猫形 PNG 或用户数据库。包内说明、文本及二进制可读字符串的 Gitleaks 扫描为零告警。

本次 Intel 运行使用 Apple Silicon 上的 Rosetta；没有新增 Intel 真机、管理员服务或完整 TUN 验收。隔离验证不启动 GUI，也不修改用户正在使用的应用、数据和网络配置。

## 首次发布安装包 SHA-256（许可补充前）

| 文件 | SHA-256 |
| --- | --- |
| LumaRoute-0.1.0-build.29-macos-arm64.dmg | `aad5b220fbd177361b5f32f243fbe13dfe593e5b85d86abbd0430d47fdfeab50` |
| LumaRoute-0.1.0-build.29-macos-arm64.zip | `3e28b8fe24bf503c55d5c6e4d50df650f1e506e7f761f6d0589ce7a74f6c4e7d` |
| LumaRoute-0.1.0-build.29-macos-x86_64.dmg | `1e43fc9308023b28e2caaedf59956d381422cd1f9b4d32926b1ba8bfe3e9b984` |
| LumaRoute-0.1.0-build.29-macos-x86_64.zip | `f243e5b2f82609459ef868251a2793e98d9ce1e4fe5980cd7bcef61304f01595` |

## 对应源码与分发

Release 附件包含 Mihomo v1.19.32、Yams 6.1.0 的官方原样源码归档，以及 GEO 规范化输入、固定工具、完整 vendored 依赖和许可证。GEO 输入由现有产物无损还原，不是原始动态网络响应的归档；其独立离线重建结果与三份原发布数据逐字节一致。

源码来源、版本和摘要见 `source-manifest.json`，全部附件摘要见 `SHA256SUMS.txt`。Mihomo 上游源码归档保留原始示例及测试资料，不对其做清洗；此前审计对该归档的示例 / 测试告警另行记录，不能与应用包的零告警混为一谈。

包继续使用 ad-hoc 签名、未公证。原 Build 17、19、21、28 安装包和发布材料仅保留在仓库外私有备份；对应 Release 与附件已按维护者要求删除，所有 Git 标签保留。

## 首次 GEO 许可补包（历史摘要）

2026-10-15 在同一 Build 29 Release 中替换安装包与 GEO 源码附件，增加逐来源署名、许可正文、MaxMind GeoLite 条款及未明确授权输入的说明。所有 Git 标签对象及其目标不变；应用源码仍为上述提交，法律声明补充来自 `2203ac0a69fc2b50589b7ef74d9171e8dfa053df`。

两种架构均仅更新 `Contents/Resources/Licenses/` 并重新 ad-hoc 签名。移除签名后的主程序与首次发布版本逐字节相同，后台服务、Mihomo、图标和 GEO 数据均未改变。新 DMG / ZIP 与对应应用逐文件一致，三种可执行文件架构和严格嵌套签名验证通过。GEO 源码附件再次从独立解包目录离线重建，三份输出摘要不变。本次未重复功能回归；前述 218 项及冒烟记录属于相同应用代码的首次验证。

| 当前文件 | SHA-256 |
| --- | --- |
| LumaRoute-0.1.0-build.29-macos-arm64.dmg | `da969b2f78c755819f0b1ed3a79c8ea8408b47f368bfccddd2f8286f0f537352` |
| LumaRoute-0.1.0-build.29-macos-arm64.zip | `5628b8cdd723278d2ffdfd838d9735689c3f9a00e52384460cf0b5ab199b12bc` |
| LumaRoute-0.1.0-build.29-macos-x86_64.dmg | `ce030d3ad722ef7efb222602de6faf75956ac9f54b49b53ed12b1b41d6e15317` |
| LumaRoute-0.1.0-build.29-macos-x86_64.zip | `ec36c60b9e2d1900aa7186084adf6152ede2ca00f4d8f0beeccd3fb0d5e82980` |

完整当前附件摘要以 Release 的 `SHA256SUMS.txt` 为准。旧附件已逐文件备份并校验；标签不移动。

## 内置 GEO 规则来源替换（前次发布）

2026-10-15 再次更新同一 Build 29 Release：biliintl / sharepoint 的输入全部改为固定的 V2Ray MIT 与 ACL4SSR CC BY-SA 4.0 来源。直接来源的原始规则、许可证、提交、URL、SHA-256 和选择行已随新输入快照保存。GEO 源码 / 许可补充提交为 `d58b9816b8d5f7580e7a462d9d16975ae41493b3`；应用 Swift 源码、Mihomo、后台服务与原 Build 29 相同，所有 Git 标签对象及目标保留。

- biliintl：由原 11 条规则改为 7 条来自新来源的规则；类别名称保留，精确域名保持精确匹配，不扩展为 Bilibili 全部国内域名。海外 API / CDN 的覆盖集合随来源更换而变化，并非旧列表逐项等价复制。
- sharepoint：3 条规则值、类型和顺序不变，来源改为 V2Ray MIT。其余 1,553 个域名分类和全部 IP 分类逐项不变，GeoIP / MetaDB 原 SHA-256 不变。
- arm64 / x86_64 各通过真实 Mihomo 的 14 个正向命中与 6 个边界反向用例。测试通过独立端口、虚拟域名到回环地址的映射、本地 HTTP 响应和内核连接记录确认规则 / 策略命中；不访问真实 Bilibili / SharePoint 账号或内容服务，不等同于这两项服务的完整业务验收。
- 两种架构各 218 项既有回归与隔离内核冒烟通过；11 项 Python 测试通过，包含来源 / 许可证被修改、来源缺少选定行、分类被注入规则的拒绝验证。
- 当前 GEO 源码附件解包后独立离线重建成功；当前双架构包通过嵌套签名、架构、GEO 摘要、所有许可证、ZIP / DMG 内容一致性核验。移除签名后的主程序与替换前逐字节相同，后台服务及内核不变。

| 当前安装包 | SHA-256 |
| --- | --- |
| LumaRoute-0.1.0-build.29-macos-arm64.dmg | `927669fedca86afa5722b8f2ce7f7e0bf76e4d7134608c737e9385098040990a` |
| LumaRoute-0.1.0-build.29-macos-arm64.zip | `fcc8fdeabedcca51288718aeb2cd69bb5ca2627ad7bb80e664cdbd071f35e0fe` |
| LumaRoute-0.1.0-build.29-macos-x86_64.dmg | `0891363bc332a8ec0f26c83b153f8fe7ef53bc6f7484c9c97a502914eabbbe42` |
| LumaRoute-0.1.0-build.29-macos-x86_64.zip | `cb0e933a1f18d0399a5ebce63ac0849f224822812f7c46e66211030909b6ed0b` |

当前 `GeoSite.dat` SHA-256 为 `f7bc69233babdfbfdd9337d85ea925b478e2dcb26817fbfd1b0fdd582448eacb`。完整附件摘要见当前 `SHA256SUMS.txt`，GEO 源码附件为 `LumaRoute-GEO-inputs-2026-10-15-licensed-rules.tar.gz`。旧 GEO 源码附件及旧安装包已备份后从当前 Release 替换。

这是安装包内置数据的替换；应用内手动在线 GEO 更新仍由用户自行下载 meta-rules-dat 上游数据，未自动套用本次固定替换，已有运行目录的数据不会被本次发包强制覆盖。未更改或启动本机已安装应用。历史 Git 标签仍指向原提交，新资源对应源码应查看 `source-manifest.json` 中的 `geo_data_source_commit` 及随附 GEO 源码归档。仓库继续私有，依赖安全未在本轮处理。

## 当前发布：在线 GEO 更新与回退的许可保护

应用与后台服务代码来自 `8a8aa1b1d01f99cbca08f81e7feaeeb6f4b81b3a`（[双架构 CI](https://github.com/onlyone1019/LumaRoute/actions/runs/38755328728) 全部通过）；后续验证工具和发布文档的提交不改变应用运行代码。Build 仍为 29，所有 Git 标签对象及目标保留，仓库继续私有。

在线更新现在先验证上游三份文件大小 / SHA-256，再使用随包固定 `GeoSite-policy.json` 完整替换 biliintl / sharepoint，其他字段按原字节保留。处理后的文件由 Mihomo 验证并执行原有事务写入 / 重启。策略 SHA-256 固定在代码中，缺失、修改或数据解析失败时拒绝操作。旧 GEO 快照回退同样先应用这两类规则；原备份保持原字节。GUI 本地内核与后台服务使用同一路径，选择应用外已下载内核时仍从应用资源取得策略。

验证结果：

- arm64 / x86_64 分别通过生产 `updateGeoData()` 入口的真实在线下载、事务写入、内核重启、失败保持原文件、旧版真实 GEO 快照回退与原件保留，12 项集成断言 / 架构。两次联网均使用上游公开发布接口，未注入下载结果。测试使用应用外的内核副本与应用内策略，覆盖后台服务选用已下载内核时的资源路径。
- 两种架构各通过 14 项离线 GEO 集成断言，包括合法 GeoSite 配合损坏 IP 文件进入事务后被内核拒绝、恢复全部旧文件、原内核继续代理真实回环 HTTP 请求，以及中断事务的恢复。
- 在线流程及旧快照回退后的实际数据，各通过 14 个正向分流与 6 个反向边界用例；两种架构各 218 项既有回归和隔离冒烟通过。
- CI 的 14 项 Swift 单元测试覆盖策略篡改、无效 / 重复 protobuf、在线摘要失败、下载失败、旧快照处理及备份保留；11 项 Python 来源与下载测试通过，离线 GEO 重建和全历史秘密扫描通过。本机命令行 SDK 缺 XCTest，单元测试以 GitHub macOS CI 结果为准。
- 双架构 DMG / ZIP 与当前应用逐文件相同；签名、三种可执行文件架构、全部许可证、策略文件及三份 GEO 摘要通过。GEO 源码附件独立解包重建通过；包内容与 GEO 源码扫描无秘密告警。

测试未修改或启动本机已安装 GUI，也没有触发真实管理员服务 / TUN 接管；Intel 仍使用 Rosetta，未新增 Intel 真机验收。当前数据不会仅因安装包替换被后台强制改写；手动更新或回退成功后应用许可规则。

| 当前安装包 | SHA-256 |
| --- | --- |
| LumaRoute-0.1.0-build.29-macos-arm64.dmg | `2ac906816811f40e0992ffeee18a3c7b3fff8dc7ce58c44c2aef27c5e8a5229f` |
| LumaRoute-0.1.0-build.29-macos-arm64.zip | `873ed49837adcc3e493866b5bacee0992977fd9fa26fe8afd320342a8824bb82` |
| LumaRoute-0.1.0-build.29-macos-x86_64.dmg | `cfeb1606d146e04db8198850435ea216d6e824a05c3443f180a325615c4223dd` |
| LumaRoute-0.1.0-build.29-macos-x86_64.zip | `3128950e7c559f8dc17c38c941025408dc07ac8d497e45b8ee56f09554a61aee` |

本次更新应用和后台服务代码、随包策略和说明；内置三份 GEO 数据的摘要不变，GeoSite 仍为 `f7bc69233babdfbfdd9337d85ea925b478e2dcb26817fbfd1b0fdd582448eacb`。Release 增加 `LumaRoute-Build29-source.tar.gz`，提供当前完整应用 / 后台服务源码，避免将未移动的标签源码误认为当前补包源码。对应提交及所有附件摘要见 `source-manifest.json` / `SHA256SUMS.txt`；上方历史摘要不适用于当前包。所有旧附件及 Git 引用已先备份并校验，历次外部备份保留，依赖安全未处理。


## 当前发布：GEO 数据与应用源码分开管理

本轮参考 Clash Verge Rev 的构建资源管理方式，从当前源码树移除 GEO 完整输入、生成策略及 GPL 工具 / vendored 依赖；Git 中只保留下载清单、固定摘要、构建 / 校验脚本和许可说明。原有 Git 历史和全部 5 个标签保留，没有重写或清理历史数据。仓库继续私有。

独立附件 `LumaRoute-GEO-inputs-2026-10-15-licensed-rules.tar.gz` 保留原内容、附件 ID 和 SHA-256 `fe12f7c56e65202bb8ad5bf523413453bb28d436b85a53ea8174bde8b3fdbacc`。构建脚本校验完整归档后临时解包，验证许可证 / 捕获来源 / 策略，再校验或离线重建数据；缓存归档放在被 Git 忽略的目录，解包的输入与工具在操作结束后删除。支持私有 GitHub 附件下载及本地离线附件，跨来源重定向剥离凭据，拒绝损坏归档、越界路径和重复文件。

当前应用源码附件不携带 GEO 数据和重建工具；应用 / 后台服务运行源码未改变，内置三份 GEO 和策略摘要未改变，在线更新及旧快照回退继续保留许可保护。应用源码、独立 GEO 材料、Mihomo / Yams 官方源码分别提供，版本和摘要见当前 `source-manifest.json` 与 `SHA256SUMS.txt`。数据管理方式调整不重新授权第三方材料，也不免除适用的 GeoLite 条款。

验证结果：

- [实现提交的双架构 CI](https://github.com/onlyone1019/LumaRoute/actions/runs/38760790203) 全部通过，包括 14 项 Swift 单元测试、17 项 Python 测试、独立 GEO 附件获取、离线重建和全历史秘密扫描。
- 本机从空缓存实际取得私有 GEO 附件成功；干净应用源码解包后不含数据 / 输入 / 工具，配合独立附件完整重建三份数据并通过 17 项 Python 测试。
- arm64 / x86_64 各通过 218 项回归、14 项 GEO 事务断言、12 项生产在线更新 / 旧快照回退断言及隔离内核冒烟。
- 双架构 ZIP / DMG 与应用逐文件一致；三种可执行程序架构、嵌套签名、全部许可、策略及三份 GEO 摘要核验通过。包内容扫描未发现秘密告警。
- 操作前备份全部 Git 引用和 11 个 Release 附件，校验文件摘要，并实际恢复验证全部 12 个引用。历次外部备份保留，未处理依赖安全。

本轮没有启动或替换本机已安装 GUI，没有新增真实管理员服务 / TUN 或 Intel 真机验收；Intel 继续通过 Rosetta 验证。Build 仍为 29，GitHub 自动生成的标签源码仍是旧版本，应使用更新后的应用源码附件。

| 当前安装包 | SHA-256 |
| --- | --- |
| LumaRoute-0.1.0-build.29-macos-arm64.dmg | `0733fabd91195c2355f8174bfe0cff3bd8c28cce91abe46c2ac84a15f9d7dfbf` |
| LumaRoute-0.1.0-build.29-macos-arm64.zip | `3106853c486114c64f057a89efecef17f819218baad92a289b7765ef0bca229d` |
| LumaRoute-0.1.0-build.29-macos-x86_64.dmg | `d9d2edc534bfdc5a5a88c9f50812d07b1f78e615d43300e28fa9abe8f028b7be` |
| LumaRoute-0.1.0-build.29-macos-x86_64.zip | `1e95afb5dd60f65600f92da80569041c8e87e161aa1a82b19272c9279dd09abe` |


## 原仓库最终历史整理

在完整备份全部引用和 11 个 Release 附件后，直接重写原仓库可控分支 / 标签的历史，移除此前提交过的 `Resources/GeoData/inputs/`。当前应用、后台服务、构建脚本、GEO 数据和策略未修改；安装包沿用此前已验证的原文件，不为历史整理重新构建。Build 17、19、21、28 标签对象不变，Build 29 标签名称保留并指向当前发布源码，GitHub 自动标签源码与本次发布实现一致，原对象及全部历史均保存在仓库外备份中。此前关于标签对象全部不变的段落是历史记录，不适用于本次整理。

应用完整源码附件和 `source-manifest.json` 更新为清理后的提交，当前 SHA-256 以 Release 的 `SHA256SUMS.txt` 为准。GeoLite 官方条款核对见 [GEO 说明](../Resources/GeoData/README.md)。本次没有新建 GitHub 仓库，没有更改可见性，也未处理依赖安全。

GitHub 服务端可能继续保留通过旧 SHA 或 PR 视图访问的旧对象。重写可控引用不等于删除服务端缓存，因此不宣称原个人信息已从 GitHub 所有存储中物理清除；仓库继续私有。
