# 第三方代码、资源与数据

LumaRoute 自行编写的代码、文档与自有素材按根目录 [MIT License](LICENSE) 授权，署名 `onlyone1019`。第三方代码、可执行程序、数据及历史素材保留各自版权和许可；根目录 MIT 不会重新授权这些内容，也不代表安装包内所有文件均为 MIT。

## 当前构建

| 组件 | 用途与版本 | 许可及版权 |
| --- | --- | --- |
| [Yams](https://github.com/jpsim/Yams/tree/6.1.0) | YAML 解析；SwiftPM 固定 6.1.0 | MIT，Copyright (c) 2016 JP Simard；见 [Yams-LICENSE](Resources/Licenses/Yams-LICENSE)。源码中 libyaml 文件自身的版权注释保留在上游源码中。 |
| [Mihomo](https://github.com/MetaCubeX/mihomo/tree/v1.19.32) | 独立运行的代理内核，v1.19.32；通过进程启动和本机 HTTP API 使用，不链接到 Swift 可执行文件 | GNU GPL v3；见 [Mihomo-LICENSE](Resources/Licenses/Mihomo-LICENSE) 及 [上游说明](Resources/Licenses/Mihomo-README.md)。安装包仅进行代码签名，未修改内核功能源码。 |
| [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) | 预置 `GeoIP.dat`、`GeoSite.dat`、`geoip.metadb`；文件名、上游地址、更新时间与 SHA-256 见 [下载清单](Resources/GeoData/release.json) | 聚合仓库 GNU GPL v3；GeoIP 包含 CC BY-SA 4.0 数据，GeoSite 包含 MIT、GPL、LGPL、WTFPL 等不同来源；完整署名、正文及授权边界见 [GEO 专项声明](Resources/Licenses/GeoData-NOTICE.md)。另见 [许可](Resources/Licenses/Meta-rules-dat-LICENSE) 和 [来源及原始数据项目说明](Resources/Licenses/Meta-rules-dat-README.md)。聚合数据中各来源的权利和声明仍归原作者，不能统一改为 MIT。 |

Yams 的源文件中还包含 libyaml，MIT 许可，Copyright (c) 2017-2020 Ingy döt Net、Copyright (c) 2006-2016 Kirill Simonov。另保留 [LibYAML-LICENSE](Resources/Licenses/LibYAML-LICENSE)，具体源码以 Yams 锁定版本内的 CYaml 为准。

### 对应源码和构建材料

- Mihomo v1.19.32：[源码目录](https://github.com/MetaCubeX/mihomo/tree/v1.19.32)、[源码归档](https://github.com/MetaCubeX/mihomo/archive/refs/tags/v1.19.32.tar.gz)。上游构建脚本、Go 模块清单和依赖锁定文件包含在源码中；内核原始文件校验值见 [Core/release.json](Resources/Core/release.json)。
- Yams 6.1.0：[源码归档](https://github.com/jpsim/Yams/archive/refs/tags/6.1.0.tar.gz)，具体 SwiftPM revision 见 [Package.resolved](Package.resolved)。
- GEO 数据：[独立分发及离线重建说明](Resources/GeoData/README.md)。完整规范化输入、固定工具、捕获来源和全部依赖源码放在 Release 的独立 GEO 附件中，不提交到当前应用源码树。基础快照从现有产物无损还原，当前快照及应用内在线更新 / 回退共同使用 V2Ray MIT / ACL4SSR CC BY-SA 4.0 的固定来源替换 biliintl 和 sharepoint；其他基础数据不冒充原始网络采集记录。应用源码附件与 GEO 附件分别提供，摘要由 `source-manifest.json` 和 `SHA256SUMS.txt` 指定。
- GEO 重建工具：独立 GEO 附件中的 `tools/geodata-snapshot/` 采用 GPL v3，保留 MetaCubeX/geo 固定 revision 的来源及修改说明；vendored 依赖分别保留其原始许可证。它不链接进 LumaRoute 的 Swift 可执行程序，也不改变自有 Swift 代码的 MIT 授权。

通过网络分发 GPL 组件时，发布者仍负责按组件协议提供对应源码获取途径，并维持其可获取性。仅有“使用了开源软件”的文字或许可证副本不能替代该义务。仍在分发的历史 Release 也需要分别保留其使用版本的材料。Build 17、19、21、28 的 Release 与附件已在仓库外备份后删除，Git 标签及历史素材的来源声明继续保留。

## 可选下载的规则订阅

[Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) 是应用提供的可选规则来源。规则由用户按需下载；并非 LumaRoute 自行编写的 MIT 规则。规则内容、更新、许可与原始数据来源以相应上游项目为准。用户自行导入的订阅及其内容不属于本仓库提供的授权范围。

## 原创猫形菜单图标

当前源代码使用 `Resources/MenuBar/LumaRoute-menu-cat*.png`。主图通过内置 imagegen 从文字提示生成，未使用 ClashX 或其他现有标志作输入；菜单栏尺寸仅作透明边界裁切与缩放。生成说明及完整提示见 [MenuBar/README.md](Resources/MenuBar/README.md)。LumaRoute 自有素材所享有的可授权权利按 MIT 提供。

## 历史 ClashX.Meta 素材

Build 17、19、21、28 曾分发的安装包及旧 Git 提交使用 ClashX.Meta 猫形菜单栏素材，按 GNU AGPL v3 保留其原许可。这些旧文件不会因为当前版本采用 MIT 或更换图标而变为 MIT。

- 来源及固定提交：[ClashX-menu-icon-NOTICE.txt](Resources/Licenses/ClashX-menu-icon-NOTICE.txt)。
- 协议正文：[ClashX-Meta-AGPL-3.0.txt](Resources/Licenses/ClashX-Meta-AGPL-3.0.txt)。
- 原作者：yichengchen 与 ClashX contributors；ClashX.Meta 作者：MetaCubeX 与 contributors。

上述历史声明为保留旧版本的来源记录，不表示当前版本继续使用该图标。
