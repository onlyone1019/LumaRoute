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

## 当前发布：许可明确的 GEO 规则来源

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
