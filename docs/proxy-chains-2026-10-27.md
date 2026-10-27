# 链式代理配置与验收（2026-10-27）

本次在 `codex/fix-subscription-switch-cache` 的 `3bfddfa` 工作区增加链式代理页面。功能尚未提交或发布；随后已按用户要求构建本机 arm64 Release 应用并覆盖 `/Applications/LumaRoute.app`。

## 使用方式

1. 导入机场订阅和 VPS 节点。两者分属不同订阅时，先创建并启用组合订阅。
2. 打开“代理 → 链式代理 → 新建链路”。
3. 填写名称，选择前置节点或策略组，再选择具体的 VPS 落地节点，保存并应用。
4. 在自定义规则、应用分流或组合分流中，将所需流量指向“链式 · 链路名称”。全局模式也可在 GLOBAL 中选择链路。
5. “测试链路”测试的是落地经过前置后的完整路径。原机场节点和原 VPS 节点继续保留，可独立使用。

链路按配置保存，订阅内容更新后重新生成，不修改订阅原文。支持编辑、停用和删除。规则仍在引用链路时，需要先修改对应规则，才能停用、删除或改名。节点改名或被移除后，需重新选择；提供器中的落地节点消失时，空链路使用 REJECT，避免意外直连。

## 实现范围

- `Profile.proxyChains` 保存链路定义，旧配置无此字段时保持兼容；沿用 SQLite 和备份流程。
- `ConfigurationLoader` 在普通配置或组合配置生成后套用链路。
- `ProxyChainComposer` 复制落地节点并设置 `dialer-proxy`，保留原节点及原分流。提供器节点通过独立提供器副本和精确匹配的策略组引用；URI 提供器的原始内容也进入独立缓存。
- 生成链路前固定原有 include-all 成员，避免原策略组自动引入链路副本。前置依赖不得引用生成的链路，内置直连、拒绝及 PASS-RULE 不作为前置或落地选项。
- 提供器副本不重复进行全量健康检查，完整链路可由页面单独测速。
- 组合分流出口列表包含当前配置的链路。

底层配置方式与 [Mihomo dialer-proxy 文档](https://wiki.metacubex.one/config/proxies/dialer-proxy/) 一致。

## 验证结果

使用项目固定的 Xcode/macOS 27.0 SDK、Swift 6 和内置 Mihomo v1.19.32，在 Apple Silicon 上验证。

| 验证 | 结果 |
| --- | --- |
| 原生 SwiftPM 构建及完整测试集 | 98 项通过，无失败 |
| 最终修改后的 ProxyChainTests 复测 | 8 项通过，无失败 |
| 本地 YAML 节点 | 真实内核完成前置 → 落地 → 本地目标请求 |
| inline 提供器节点及名称前缀 | 两跳请求通过，精确选择落地 |
| URI 节点列表 | 两跳请求通过，原始提供器缓存完整 |
| HTTP 远程提供器 | 两跳请求通过，包含正则特殊字符的节点名称正确匹配 |
| 数据库只读导致保存失败 | 恢复内核原配置，内存和已保存链路保持原值 |
| 无效落地、删除被引用链路 | 操作被拒绝，原状态保留 |
| 提供器落地节点消失 | 链路候选变为 REJECT，无直连兜底 |
| 原生页面操作 | 新建、选择、保存、测速、停用及删除通过；窄窗口布局和表单已视觉检查 |

可运行以下命令复验：

```sh
source script/build_environment.sh
swift test --build-system native --sdk "$SDK_PATH"
python3 script/check_proxy_chains.py
```

`check_proxy_chains.py --ui` 打开隔离页面，使用独立数据目录、动态端口和本地 CONNECT 服务。测试编译实际 AppStore 的临时副本，仅将其中的已安装服务选择关闭，以确保不访问现有后台服务、不修改系统代理或 TUN。测试不是对真实机场/VPS 的速度、稳定性或具体代理协议的验收。

## 开始任务时已有的未提交改动

这些改动已保留，本次没有提交或回退：

| 文件 | 原有改动 |
| --- | --- |
| `Sources/LumaRoute/Views/SettingsTabs.swift` | 局域网共享开关、用户名、密码显示和重新生成 |
| `Sources/LumaRouteCore/Models.swift` | 局域网共享设置及 16 位随机密码生成 |
| `Sources/LumaRouteCore/PersistenceDecoding.swift` | 新字段持久化解码，旧配置默认关闭共享 |
| `Sources/LumaRouteCore/ConfigComposer.swift` | 代理监听局域网、用户名密码认证、私网地址限制；控制接口保持本机 |
| `Sources/LumaRouteCore/CoreRunner.swift` | 监听或认证变更时重启内核，使旧监听/密码失效 |
| `Sources/LumaRouteCore/LocalStore.swift` | 备份不携带共享密码，恢复时共享默认关闭 |
| `Tests/LumaRouteCoreTests/LANSharingTests.swift` | 6 项局域网共享相关测试，已随本次完整测试通过 |

本次测试数据库、原生预览应用、日志、临时源文件和编译缓存均在验收结束后清理；保留源码、测试脚本、本报告及原有最新发布产物。

## 本机安装

- 使用 `./script/build_and_run.sh --build-only` 构建当前工作区，包含链式代理及此前的局域网共享改动。
- 本地版本号仍为 0.1.11 · Build 41；没有创建新公开版本或修改发布包。
- macOS 27.0 SDK / 最低 macOS 14.0 校验及应用深层签名校验通过。
- 已覆盖 `/Applications/LumaRoute.app` 并启动，确认“代理 → 链式代理”页面可见；原有组合配置仍在。
- 安装后的主程序与构建产物 SHA-256 一致：`2cd0b5cd6cce9fbe60ad3dbaecab2f6bc1449c77e576e6bc8af9356875068f3d`。
- 后台服务按应用现有的“完成更新”流程同步并请求 macOS 授权。安装临时备份及本次编译缓存验收后删除。
