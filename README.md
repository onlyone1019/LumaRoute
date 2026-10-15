<div align="center">
  <img src="Resources/AppIcon/LumaRoute-icon.png" alt="LumaRoute 图标" width="112" />
  <h1>LumaRoute</h1>
  <p><strong>为 macOS 打造的原生代理管理工具</strong></p>
  <p>订阅、节点、分流与网络接管，在一个轻巧的桌面应用里完成。</p>
  <p>
    <img alt="macOS 14 或更新版本" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
    <img alt="SwiftUI 原生界面" src="https://img.shields.io/badge/UI-SwiftUI-F05138?logo=swift&amp;logoColor=white" />
    <img alt="Mihomo 内核" src="https://img.shields.io/badge/Core-Mihomo-0A84FF" />
    <img alt="开发预览版" src="https://img.shields.io/badge/Status-Preview-8B5CF6" />
  </p>
  <p>
    <a href="#功能一览">功能一览</a> ·
    <a href="#界面展示">界面展示</a> ·
    <a href="#下载安装">下载安装</a> ·
    <a href="#构建与安装">源码构建</a> ·
    <a href="#快速上手">快速上手</a> ·
    <a href="#常见问题">常见问题</a>
  </p>
</div>

<br />

<img src="docs/images/overview.png" alt="LumaRoute 概览：连接状态、当前节点和流量趋势，使用演示数据" width="100%" />

LumaRoute 使用 **SwiftUI + AppKit** 构建桌面界面，由独立的 **[Mihomo](https://github.com/MetaCubeX/mihomo)** 内核处理代理与分流。保留订阅提供的策略组和规则，同时提供本地覆盖、自动选择与菜单栏快捷操作。

> 当前为开发预览版，提供 Apple Silicon 和 Intel 安装包，也支持本机自行构建。默认采用本地 ad-hoc 签名，无需购买 Apple 开发者证书；安装包未经过 Developer ID 签名与 Apple 公证。

## 功能一览

| 功能 | 支持内容 |
| --- | --- |
| **订阅管理** | 链接、文件与拖放导入；支持 YAML、URI 和 Base64 节点配置；多配置切换、手动及定时更新 |
| **订阅兼容** | 每个订阅独立设置 User-Agent；区分网络、HTTP、格式及内核校验错误；失败保留上次可用配置 |
| **多订阅组合** | 勾选多个订阅聚合节点；可按域名指定订阅、选择基础规则和兜底出口；保留单订阅模式 |
| **节点与策略组** | 保留原分组名称、顺序与引用；节点切换、分组测速、批量测速、地区筛选与延迟排序 |
| **自动切换** | 保持订阅策略、最低延迟选择、故障转移；按订阅保存本地策略，支持恢复自动选择 |
| **规则订阅** | 内置 Loyalsoldier 的 13 个规则集；选择目标策略组、匹配优先级与更新周期；失败保留旧规则 |
| **自定义规则** | 域名、域名后缀、关键词、IPv4 / IPv6 网段；支持排序、撤销与应用 |
| **快捷与应用分流** | 从连接右键选择出口；可选择应用，按进程名称或完整路径分流；连接详情显示命中规则、来源订阅和节点 |
| **网络诊断** | 检查控制接口、代理端口、系统代理、TUN 状态、DNS 和真实出口访问；可取消，不修改配置 |
| **更新变化** | 显示订阅节点及策略组增删、节点参数变化，提示原选中节点被移除 |
| **系统代理与 TUN** | 独立开关；可配置协议栈、路由、DNS、MTU、IPv6 与局域网排除 |
| **连接与日志** | 按进程、目标、协议和策略筛选连接；关闭单条或全部连接；搜索日志、暂停及导出诊断 |
| **菜单栏常驻** | 原生级联菜单、节点切换、双行实时速率、测速、系统代理与 TUN 快捷操作 |
| **维护与恢复** | 内核和 GEO 数据更新、校验与回退；本地备份、恢复与后台服务安装后自动刷新 |

## 界面展示

以下图片由**当前 SwiftUI 界面组件使用演示数据离线渲染**，用于展示实际布局；其中订阅、节点、流量及连接均为示例，不包含真实账号或网络记录。早期设计稿另见 [design](design/)。

<table>
  <tr>
    <td width="50%"><strong>订阅管理</strong><br /><img src="docs/images/subscriptions.png" alt="订阅管理演示：多配置、额度与更新状态" /></td>
    <td width="50%"><strong>代理与策略组</strong><br /><img src="docs/images/proxies.png" alt="代理页演示：分组、节点选择与测速入口" /></td>
  </tr>
  <tr>
    <td><strong>规则订阅</strong><br /><img src="docs/images/rule-subscriptions.png" alt="规则订阅演示：规则集、策略映射和更新周期" /></td>
    <td><strong>系统代理与 TUN</strong><br /><img src="docs/images/tun-settings.png" alt="网络设置演示：系统代理、TUN、协议栈与 DNS" /></td>
  </tr>
  <tr>
    <td><strong>连接查看器</strong><br /><img src="docs/images/connections.png" alt="连接页演示：进程、目标、策略和流量" /></td>
    <td><strong>运行日志</strong><br /><img src="docs/images/logs.png" alt="日志页演示：级别、来源、搜索与诊断导出" /></td>
  </tr>
</table>

<details>
  <summary>查看自定义规则界面</summary>
  <br />
  <img src="docs/images/custom-rules.png" alt="自定义规则演示：类型、匹配内容、目标策略与执行顺序" width="100%" />
</details>

## 下载安装

安装包已包含多订阅组合：在“订阅 → 组合订阅”勾选 2 至 16 个来源，保存并启用后，可在“规则 → 域名分流”选择各个域名使用的订阅。普通订阅的“启用”按钮仍可直接切回单订阅模式。使用说明和实测结果见 [多订阅组合验收记录](docs/subscription-composition-2026-10-15.md)。

同时提供“连接 → 右键创建分流”、“规则 → 应用分流”、“概览 → 网络诊断”和订阅更新变化详情。按应用分流需规则模式和具备进程识别权限的后台服务；应用使用辅助进程联网时，优先从实际连接创建规则。详见 [快捷分流与诊断验收记录](docs/routing-tools-2026-10-15.md)。

**当前预览版：[0.1.0 · Build 29](https://github.com/onlyone1019/LumaRoute/releases/tag/v0.1.0-build.29)** · macOS 14+ · Apple Silicon / Intel

Build 29 增加 MIT 署名与完整第三方许可、原创猫形菜单图标，以及可离线重建的 GEO 输入和完整生成依赖，并修复云端构建兼容性。详见 [Build 29 发布与验证记录](docs/build29-release-verification-2026-10-15.md)。

**从 Build 21 及以后版本更新，保留现有 SQLite 业务数据；从 Build 20 或更早版本更新，不自动迁移旧 JSON、订阅文件或钥匙串数据，需重新添加订阅，旧文件原样保留。**

| 下载 | 安装方式 |
| --- | --- |
| [Apple Silicon · DMG（推荐）](https://github.com/onlyone1019/LumaRoute/releases/download/v0.1.0-build.29/LumaRoute-0.1.0-build.29-macos-arm64.dmg) | M 系列 Mac；打开后安装到应用程序 |
| [Apple Silicon · ZIP](https://github.com/onlyone1019/LumaRoute/releases/download/v0.1.0-build.29/LumaRoute-0.1.0-build.29-macos-arm64.zip) | M 系列 Mac；解压后放入“应用程序” |
| [Intel · DMG（推荐）](https://github.com/onlyone1019/LumaRoute/releases/download/v0.1.0-build.29/LumaRoute-0.1.0-build.29-macos-x86_64.dmg) | Intel Mac；打开后安装到应用程序 |
| [Intel · ZIP](https://github.com/onlyone1019/LumaRoute/releases/download/v0.1.0-build.29/LumaRoute-0.1.0-build.29-macos-x86_64.zip) | Intel Mac；解压后放入“应用程序” |
| [SHA-256 校验文件](https://github.com/onlyone1019/LumaRoute/releases/download/v0.1.0-build.29/SHA256SUMS.txt) | 核对下载文件的完整性 |

更新旧版前先关闭系统代理与 TUN，再退出并在原安装位置替换应用。重新打开后会自动判断服务是否需要同步，点击“完成更新”并在 macOS 授权窗口确认即可。安装包包含内核、GEO 数据与后台服务资源，无需另外下载编译工具。

这是未公证的本地签名预览包，下载后可能被 macOS 阻止。确认来源后，可在“系统设置 → 隐私与安全性”按系统提示手动允许打开；系统仍不允许时，可使用下面的源码构建方式。完整说明见 [Build 29 发布说明](docs/releases/v0.1.0-build.29.md)。

请按芯片架构选择安装包：M 系列使用 `arm64`，Intel 使用 `x86_64`。Intel 包在 Apple Silicon 上通过 Rosetta 验证，尚未完成 Intel 真机验收。

## 构建与安装

### 环境要求

- **macOS 14 或更新版本**。
- **Xcode 或 Apple Command Line Tools**，提供 Swift 编译器及 macOS SDK。
- **Python 3**，用于取得和校验官方内核、调度 GEO 数据离线重建。
- **Go 1.23 或更新版本**，首次从源码构建时用于从固定输入离线生成 GEO 数据；安装包用户无需安装 Go。
- 首次构建需联网访问 GitHub，获取 Yams 依赖与 Mihomo 内核。GEO 数据使用仓库内固定输入离线重建。

脚本根据本机架构选择 `arm64` 或 `x86_64` 内核。现有运行验收在 Apple Silicon Mac 上完成。

如果还没有安装命令行开发工具：

```sh
xcode-select --install
```

### 从源码构建

```sh
git clone https://github.com/onlyone1019/LumaRoute.git
cd LumaRoute
./script/build_and_run.sh --build-only
```

构建脚本会取得所需依赖和内核，从固定输入验证或离线重建 GEO 数据，执行 Release 构建、生成应用图标，并对应用和内核进行本地 ad-hoc 签名。GEO 的可编辑输入、固定工具和全部依赖源码已随仓库提供，不依赖会滚动变化的 `latest` 规则；见 [GEO 输入快照](Resources/GeoData/inputs/2026-10-13-normalized/README.md)。生成的应用位于：

```text
dist/LumaRoute.app
```

如需构建后直接启动，可运行 `./script/build_and_run.sh`。该命令会先退出已运行的 LumaRoute；只构建时使用 `--build-only`。

指定 Intel 架构构建和打包（使用独立的编译目录和应用包）：

```sh
LUMAROUTE_ARCH=x86_64 ./script/build_and_run.sh --build-only
./script/package_release.sh dist/x86_64/LumaRoute.app
```

应用位于 `dist/x86_64/LumaRoute.app`，安装包位于 `dist/releases/<版本标签>/`。同一版本的校验文件包含两种架构已生成的 DMG 和 ZIP；在 Apple Silicon 上运行 Intel 产物需安装 Rosetta。

### 安装到“应用程序”

1. 退出正在运行的旧版 LumaRoute。
2. 在 Finder 中打开项目的 `dist` 文件夹，将 `LumaRoute.app` 拖到“应用程序”。
3. 从“应用程序”启动 LumaRoute。
4. 如需系统代理或 TUN，按下面的步骤安装后台服务。

**先确定应用安装位置，再安装后台服务。** 不要直接修改已经安装的 `.app` 内部文件；重新构建后，使用新应用包整体替换。

如果主窗口已打开但 Dock 图标仍缺失，可把原样应用包放到“应用程序”内的 `LumaRoute` 文件夹，即 `/Applications/LumaRoute/LumaRoute.app`，应用名称保持 **LumaRoute**。这是本机经实际确认的路径规避方式，尚未确定底层系统原因；后续更新应替换该路径中的应用，不另装回旧位置。未修改应用包的移动无需重新同步后台服务。详见 [Dock 验收记录](docs/dock-performance-2026-10-14.md)。

### 安装后台服务

系统代理与 TUN 由独立的管理员后台服务管理：

以下流程适用于 Build 19 及以后版本：

1. 首次使用时，点击“启用网络功能”，或直接开启系统代理 / TUN。更新应用后如需要同步，点击自动出现的“完成更新”。
2. 在 **macOS 管理员授权窗口**中完成授权，密码不会交给应用。
3. 应用自动同步并连接后台服务，无需打开 Terminal、重启应用或手动“重新检查”。从网络开关进入授权时，完成后会继续应用刚才选择的开关状态。

取消授权后可稍后重试。需要手动同步时，可用 **设置 → 网络 → 管理服务 → 重新同步服务**；当前接管会先暂停，完成后恢复原设置。旧版的 `.command` 安装脚本仍随包提供，作为兼容入口。

安装器本身不会开启网络接管。后台服务仍绑定具体构建；替换或重新编译应用后可能需要一次授权同步，同一已授权版本正常重开不会重复安装。Build 21 起业务数据及密钥保存在本机 SQLite 数据库，不再访问钥匙串。详见 [Build 19 授权流程验收](docs/service-setup-2026-10-15.md)。

<details>
  <summary>高级构建选项</summary>

指定已安装的 SDK：

```sh
LUMAROUTE_SDK="/path/to/MacOSX.sdk" ./script/build_and_run.sh --build-only
```

脚本会检查已安装 SDK；CLT 27 缺少 SwiftUI 宏插件且本机装有 26.5 SDK 时，会采用 26.5 SDK，不修改全局 Xcode 配置。最低运行版本与构建 SDK 版本是两项独立设置。

如已准备好有效的 Developer ID 身份，可指定签名身份：

```sh
LUMAROUTE_SIGNING_IDENTITY='Developer ID Application: 你的身份' \
  ./script/build_and_run.sh --build-only
```

该选项仅选择代码签名身份，**不代表已自动完成公证或具备分发条件**。

</details>

## 快速上手

### 1. 导入订阅

在 **订阅 → 添加订阅** 中填写名称和链接；也可以导入文件，或把配置拖入订阅页的虚线区域。

- 订阅链接保存在本机 SQLite 数据库中。
- 默认使用 Clash Meta 兼容 User-Agent；可为每个订阅单独指定。
- 已有订阅可在 **更多 → 订阅设置** 中修改或恢复默认 User-Agent。
- 导入、更新会经过格式与内核校验；失败时显示原因并保留已有可用配置。

导入成功后，点击该配置的 **启用**。

### 2. 选择节点或自动策略

打开 **代理**，展开策略组，选择节点并使用，或进行延迟测速。应用保留机场的分组名称、候选项与组间引用。

在分组的策略设置中，可选择：

| 策略 | 行为 |
| --- | --- |
| 保持订阅策略 | 沿用机场配置中的选择方式 |
| 自动选择最低延迟 | 根据测速结果自动选择候选节点 |
| 故障转移 | 按候选顺序选择可用节点 |

自动组手动选择节点后会进入固定状态；点击 **恢复自动** 可交回自动策略。

### 3. 开启网络接管

后台服务安装完成后，在概览、网络设置或菜单栏开启：

- **系统代理**：供遵循 macOS 系统代理设置的应用使用。
- **TUN 模式**：接管未使用系统代理的应用流量，可进一步配置路由与 DNS。

默认混合代理端口为 **19790**，控制端口为 **19791**，控制接口仅监听本机。端口可在 **设置 → 通用** 中调整；多个代理工具同时运行时，请使用不同端口，并确定由哪个工具接管系统代理。

关闭窗口后，LumaRoute 继续在菜单栏运行；退出应用会停止其管理的内核并恢复属于自己的网络设置。

### 4. 添加规则订阅

打开 **规则 → 规则订阅 → 添加规则订阅**，选择 [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) 的规则集，再选择直连、拦截或当前机场的策略组。

默认使用“补充机场规则”，执行顺序为：

```text
自定义规则 → 优先规则订阅 → 机场原规则 → 补充规则订阅 → 机场兜底
```

**机场已经匹配的分流优先保留，原始订阅文件不改写。** 若需要广告拦截等先于机场规则匹配，可主动选择“优先于机场规则”，界面会说明覆盖影响。

- 每条规则订阅绑定当前机场配置，切换机场时分别管理。
- 默认每 24 小时自动更新，可修改周期或关闭自动更新。
- 应用运行且内核就绪时执行到期更新；退出、休眠期间不执行，恢复后补做。
- 下载或加载失败保留旧规则；目标策略组失效时暂停对应规则订阅并提示。

更多说明见 [规则订阅文档](docs/rule-subscriptions-2026-10-14.md)。

### 5. 查看连接、日志与备份

在 **连接** 页查看请求的进程、目标、代理链和命中规则，关闭选中连接或全部连接；在 **日志** 页搜索、暂停或导出诊断信息。

在 **设置 → 更新与备份** 中创建本地备份、恢复配置，或维护内核与 GEO 数据。更新内核前需关闭系统代理与 TUN。

### 快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘N` | 添加订阅 |
| `⌘⇧P` | 连接 / 暂停连接 |
| `⌘D` | 从菜单栏打开控制台 |
| `⌘T` | 从菜单栏发起延迟测速 |
| `⌘Q` | 退出应用 |

## 常见问题

<details>
  <summary><strong>自己使用也需要购买签名证书吗？</strong></summary>

不需要。默认构建使用免费的本地 ad-hoc 签名，用于本机运行和后台服务身份校验。向其他用户分发时的 Developer ID 签名与公证，需要另行准备。

</details>

<details>
  <summary><strong>为什么重新构建后需要更新后台服务？</strong></summary>

本机服务保存 root-owned 应用快照，精确匹配构建身份，防止其他程序冒用权限。新构建的身份发生变化，所以需要通过“管理服务”重新安装同步。只移动未修改的应用包不会改变构建身份。

</details>

<details>
  <summary><strong>订阅在其他客户端能导入，这里却失败怎么办？</strong></summary>

先核对错误类型，再尝试在订阅设置中使用服务商要求的 User-Agent。默认标识兼容 Clash Meta，但不能保证所有服务商都返回相同格式。若提示策略组或节点不存在，需要检查服务商返回的完整配置；应用会保留上次可用版本。

参见 [订阅兼容性说明](docs/subscription-client-compatibility-2026-10-14.md)。

</details>

<details>
  <summary><strong>能和 Clash Verge 等代理工具同时运行吗？</strong></summary>

可以保留多个应用，但端口不能冲突，系统代理和 TUN 的归属也需明确。其他软件可能重新设置代理或路由；LumaRoute 检测到自己的系统代理被覆盖后，会停止接管并保留外部修改。避免让多个工具同时持续接管网络。

</details>

<details>
  <summary><strong>配置和凭据保存在哪里？</strong></summary>

应用数据目录为：

```text
~/Library/Application Support/LumaRoute
```

Build 21 起，应用业务数据统一保存在 `~/Library/Application Support/LumaRoute/lumaroute.sqlite`，目录权限为 `0700`、数据库为 `0600`。新库从空状态开始，不迁移旧 JSON、订阅文件或钥匙串记录，旧数据原样保留。普通备份使用 SQLite 格式，包含配置、规则缓存、策略和设置，完整订阅链接及控制密钥保留在本机数据库中，不随备份导出。恢复时选择包含 `lumaroute.sqlite` 的新版备份目录。配置文件也可能包含节点认证信息，因此备份应作为私有数据保管。

</details>

## 开发与验证

```sh
# 先生成 Release 构建产物
./script/build_and_run.sh --build-only

# 原生回归检查
.build/out/Products/Release/LumaRouteCLI verify
```

命令行验证产物路径取决于本机 Swift 构建系统；若上述路径不存在，可在相同构建配置和 SDK 下通过 `swift build --configuration release --show-bin-path` 查询。

现有验证记录包括：**56 项原生回归、79 项内核集成、37 项规则订阅集成**，以及独立的内核维护、GEO、调度与生命周期检查。测速回归覆盖连续批次、失败、取消和立即重测。详细范围和证据以各文档为准。

当前本机环境缺少 XCTest 模块，因此现有验证采用 CLI 原生回归和真实 Mihomo 集成，仓库中的 XCTest 源码不代表已经全量运行通过。实际登录自启、物理断网重连仍待完成验收。

| 文档 | 内容 |
| --- | --- |
| [功能验收](docs/functional-verification.md) | 受控内核集成、网络接管与恢复 |
| [按钮与崩溃检查](docs/button-audit-2026-10-14.md) | 界面操作、异常输入与失败恢复 |
| [规则订阅](docs/rule-subscriptions-2026-10-14.md) | 合并顺序、更新与隔离验证 |
| [订阅选项](docs/subscription-options-2026-10-14.md) | 独立 User-Agent 与错误提示 |
| [批量测速修复](docs/latency-crash-2026-10-14.md) | 崩溃复现与回归验证 |
| [需求状态](docs/requirements.json) | 功能覆盖及尚待验收项目 |

<details>
  <summary>项目结构</summary>

```text
Sources/
├── LumaRoute/         # SwiftUI 界面、AppKit 菜单与应用状态
├── LumaRouteCore/     # 配置、存储、内核生命周期与 API
├── LumaRouteHelper/   # 管理员后台服务
└── LumaRouteCLI/      # 回归和集成验证工具
Tests/                # XCTest 源码
docs/                 # 使用说明、验证记录与界面展示
script/               # 构建、资源下载、服务安装与检查脚本
design/               # 早期七页设计稿
Resources/            # 图标、第三方许可及资源下载记录
```

</details>

## 致谢与第三方许可

LumaRoute 自行编写的代码、文档与自有素材采用 [MIT License](LICENSE)，Copyright (c) 2026 onlyone1019。第三方组件保留原协议，完整范围及源码获取说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

- [Mihomo](https://github.com/MetaCubeX/mihomo)：代理内核，官方许可随应用附带，见 [Mihomo LICENSE](Resources/Licenses/Mihomo-LICENSE)。
- [Yams](https://github.com/jpsim/Yams)：YAML 解析；构建时将其 LICENSE 复制到应用包。
- [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules)：可选的在线规则订阅来源。
- 当前源码使用 [imagegen 生成的原创猫形菜单图标](Resources/MenuBar/README.md)。已发布 Build 17–28 仍包含 ClashX.Meta 历史素材，其 AGPL-3.0 声明见 [NOTICE](Resources/Licenses/ClashX-menu-icon-NOTICE.txt)。
- [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)：预置 GEO 数据，保留上游许可与原始数据来源声明。

应用图标与早期设计稿保存在本仓库中。第三方代码、资源及规则库分别遵循其自身许可。

Build 29 提供 Apple Silicon / Intel 两种架构；安装包、校验文件与对应源码材料见上方 Release。参与开发见 [CONTRIBUTING.md](CONTRIBUTING.md)，安全问题见 [SECURITY.md](SECURITY.md)。CI 定义用于双架构构建与秘密扫描；只有实际运行通过后才能视为验证结果。
