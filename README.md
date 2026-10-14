# LumaRoute

原生 macOS 代理管理工具，使用 SwiftUI 管理随应用打包的 Mihomo。页面包含概览、订阅、代理、连接、规则、日志和设置。

## 构建与启动

要求 macOS 14+、Apple Command Line Tools 或 Xcode、Python 3；首次构建需要联网下载 Yams、官方内核与规则数据库。

```sh
./script/build_and_run.sh
```

输出位于 `dist/LumaRoute.app`。只构建、不启动：

```sh
./script/build_and_run.sh --build-only
```

本机当前第 17 版位于 `/Applications/LumaRoute.app`，可从“应用程序”打开。第 14 版曾通过改用 `LumaRoute Local.app` 路径解决 Dock 显示异常，对照记录见 `docs/dock-performance-2026-10-14.md`；第 15 版修复批量测速闪退，验证见 `docs/latency-crash-2026-10-14.md`；第 16 版修复异常订阅流量溢出崩溃，并完成主要按钮和失败路径复查，范围见 `docs/button-audit-2026-10-14.md`；第 17 版加入 Loyalsoldier 规则订阅，使用与验收见 `docs/rule-subscriptions-2026-10-14.md`。应用图标由内置 imagegen 生成，透明源图位于 `Resources/AppIcon/LumaRoute-icon.png`，提示词见 `design/app-icon-prompt.md`。规范构建自动生成含10种尺寸表示的 `AppIcon.icns` 并写入应用包。重新构建后，需同步本机后台服务以匹配新的构建身份；只移动未改动的安装包无需重新授权。

项目配置了 Codex Run 入口。脚本会优先使用可用 SDK；本机 CLT 27 缺少 SwiftUI 宏插件时自动采用已安装的 26.5 SDK，不修改全局 Xcode 设置。

本机自用构建自动使用免费的 ad-hoc 签名，无需购买开发者账号、证书或公证。重新编译后，macOS 可能要求重新允许应用读取本机钥匙串；密码由用户在系统弹窗输入。公开分发的 Developer ID 签名与公证另行配置。

规则页的“规则订阅”可添加 [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) 的 13 个规则集，选择目标策略组、匹配优先级及自动更新周期。默认绑定当前机场配置，按“自定义规则 → 优先规则订阅 → 机场原规则 → 补充规则订阅 → 机场兜底”匹配；默认使用补充模式。新建规则订阅需主动添加，更新应用不会自动覆盖机场规则。自动更新仅在应用运行且内核就绪时执行，休眠/退出期间不执行，恢复后补做已到期任务。

## 使用

- 默认混合端口 `19790`、控制端口 `19791`。首次打开不接管系统网络。
- 在订阅页添加链接，或导入 / 拖入 YAML、URI、Base64 节点配置。链接保存在本机钥匙串；下载地址不会写入进程参数。
- 添加远程订阅时可填写独立的 User-Agent；已有订阅在“更多 → 订阅设置”修改或恢复默认。留空使用 Clash Meta 兼容标识，手动和自动更新使用同一份订阅设置。
- 订阅错误提示区分网络连接、HTTP 状态、返回网页、空响应、编码/格式和内核校验问题，并提供处理建议；导入失败保留表单，更新失败保留上次可用配置。
- 分组卡片保留订阅顺序、名称、候选和组间引用。展开可切换或测试节点。
- 在分组的策略设置中选择保持订阅、最低延迟或故障转移；支持日本候选、测试周期与切换容差。本地覆盖按订阅保存，更新订阅后保留。
- 自动组手动选择后会固定节点，点击恢复自动可解除固定。
- 设置 → 更新与备份可查询官方稳定版，校验 SHA256 后下载并切换内核，支持回退上次版本；管理员服务独立校验和管理官方内核。更新前需暂停系统代理与 TUN。普通内核和管理员内核更新/回退均已实测。
- 系统代理和 TUN 通过管理员安装的独立 system launchd 服务管理。在设置 → 网络 → 管理服务选择“安装并授权网络服务”，在 Terminal 手动完成管理员密码输入。安装不会自动接管网络，无需 Apple 开发者证书。服务保存 root-owned 应用快照，精确绑定当前构建与本机用户；重建应用后需同步更新服务。
- 完整网络服务安装后，服务持续管理内核，关闭系统代理/TUN 只恢复网络设置，避免 root 与普通用户之间复用端口的冲突。退出应用会恢复网络并停止自己的内核。
- Clash Verge 等工具同时运行时可能重新写入系统代理。检测到覆盖时，LumaRoute 会停止接管并保留外部修改。当前共存实测中，先开启 TUN、路由稳定后再开启系统代理可正常运行；不能保证两个工具同时持续接管。
- 关闭主窗口后继续在菜单栏运行；退出会停止应用管理的内核。添加订阅快捷键为 `⌘N`，连接快捷键为 `⌘⇧P`。
- 菜单栏采用 ClashX 经典原生下拉菜单：出站模式、策略组与节点级联菜单、系统代理、TUN、实时速率、测速、配置和帮助。猫形模板图标的来源及许可随应用附带；原应用图标保留。显示实时速率时菜单栏项固定为 60 点宽，双行速率右对齐，避免流量变化挤动相邻图标；当前间距已由用户确认。

数据保存在 `~/Library/Application Support/LumaRoute`。本地备份包含配置、规则、策略和设置，链接凭据留在本机钥匙串。

## 验证与状态

```sh
.build/debug/LumaRouteCLI verify
```

受控回环测试与真实订阅的验证过程见 `docs/functional-verification.md` 和 `docs/subscription-verification.md`；独立 User-Agent 与错误提示验收见 `docs/subscription-options-2026-10-14.md`；完整验收状态见 `docs/requirements.json`。最新56项原生回归通过；本轮79项真实内核集成、16项内核维护事务、11项GEO集成及7项生命周期检查通过。无证书后台服务、系统代理启停和绕过、四种TUN协议栈的真实IPv4流量、DNS/路由恢复、内核与GEO更新回退、备份恢复、GUI、内核及后台服务异常恢复（包括TUN开启时）、服务卸载重装均已实测，七页视觉核对见 `design-qa.md`。

当前构建可供本机日常试用。已验证接管关闭及TUN开启时的真实睡眠唤醒；已验证IPv4网络经代理节点的真实IPv6 TUN出口及关闭恢复；实际登录自启、物理断网重连仍按用户选择延后，以验证记录最新章节为准。

GEO 数据库支持校验更新与回退；本地备份可恢复订阅、规则和设置，恢复前自动保留一份备份。

当前 CLT 没有 XCTest 模块，使用 CLI 原生回归和真实 Mihomo 集成验证；XCTest 源码保留在 `Tests`，不以 CLI 检查冒充 XCTest 全量通过。

## 目录

`Sources/LumaRoute` 为界面与应用状态，`LumaRouteCore` 为配置、存储、内核和 API，`LumaRouteHelper` 为授权后台服务，`LumaRouteCLI` 为本地验证工具。七页原设计图位于 `design`，代理页已按用户后续要求改为可展开分组卡片。

官方 Mihomo 的许可与说明随应用复制到 `Contents/Resources/Licenses`。构建下载记录在 `Resources/Core/release.json` 和 `Resources/GeoData/release.json`，下载时验证发布资产 SHA256。

使用本机已有的有效签名身份构建：

```sh
LUMAROUTE_SIGNING_IDENTITY='Developer ID Application: 你的身份' ./script/build_and_run.sh --build-only
```

上述证书签名仅供另行配置的分发构建使用，本机自用保持默认 ad-hoc 即可。签名身份必须实际存在于本机钥匙串。
