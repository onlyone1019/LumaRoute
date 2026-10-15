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

## GEO 许可补充后的安装包

2026-10-15 在同一 Build 29 Release 中替换安装包与 GEO 源码附件，增加逐来源署名、许可正文、MaxMind GeoLite 条款及未明确授权输入的说明。所有 Git 标签对象及其目标不变；应用源码仍为上述提交，法律声明补充来自 `2203ac0a69fc2b50589b7ef74d9171e8dfa053df`。

两种架构均仅更新 `Contents/Resources/Licenses/` 并重新 ad-hoc 签名。移除签名后的主程序与首次发布版本逐字节相同，后台服务、Mihomo、图标和 GEO 数据均未改变。新 DMG / ZIP 与对应应用逐文件一致，三种可执行文件架构和严格嵌套签名验证通过。GEO 源码附件再次从独立解包目录离线重建，三份输出摘要不变。本次未重复功能回归；前述 218 项及冒烟记录属于相同应用代码的首次验证。

| 当前文件 | SHA-256 |
| --- | --- |
| LumaRoute-0.1.0-build.29-macos-arm64.dmg | `da969b2f78c755819f0b1ed3a79c8ea8408b47f368bfccddd2f8286f0f537352` |
| LumaRoute-0.1.0-build.29-macos-arm64.zip | `5628b8cdd723278d2ffdfd838d9735689c3f9a00e52384460cf0b5ab199b12bc` |
| LumaRoute-0.1.0-build.29-macos-x86_64.dmg | `ce030d3ad722ef7efb222602de6faf75956ac9f54b49b53ed12b1b41d6e15317` |
| LumaRoute-0.1.0-build.29-macos-x86_64.zip | `ec36c60b9e2d1900aa7186084adf6152ede2ca00f4d8f0beeccd3fb0d5e82980` |

完整当前附件摘要以 Release 的 `SHA256SUMS.txt` 为准。旧附件已逐文件备份并校验；标签不移动。
