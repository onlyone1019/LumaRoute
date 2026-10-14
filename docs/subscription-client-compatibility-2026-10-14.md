# 订阅客户端识别兼容修复

问题：新订阅下载成功，但 Mihomo 校验报告策略组引用的“自动选择”不存在。

对照 Clash Verge Rev 源码（commit `5b10331022940dfbd049adfa6f714d3da2d5a6ef`）：

- `src-tauri/src/utils/network.rs:246`：默认使用 `clash-verge/v版本号`，支持自定义 User-Agent。
- `src-tauri/src/config/prfitem.rs:259`：下载远程订阅，默认直连；随后解析 YAML、读取用量及更新周期。
- Mihomo 官方文档的 `global-ua` 默认值为 `clash.meta`：https://github.com/MetaCubeX/Meta-Docs/blob/main/docs/config/general.md 。

在同一地址、相同直连传输条件下，只改变 User-Agent：

| 请求标识 | 节点 | 源策略组 | 结果 |
| --- | ---: | ---: | --- |
| `clash-lumaroute/0.1.0` | 0 | 1 | 引用了缺失策略组，校验失败 |
| `clash-verge/v2.4.5` | 23 | 3 | 结构完整 |
| `clash.meta/1.19.32 LumaRoute/0.1.0` | 23 | 3 | 真实内核校验、启动成功 |

据此确认该服务商根据客户端标识返回不同订阅内容。修复在 SubscriptionFetcher 中统一 Meta 兼容标识，并让 URLSession 和直连 curl 共用；保留服务商的原始节点、策略组和引用。

验证结果：

- 新增本机按 User-Agent 返回不同配置的 fixture。旧实现复现缺失组错误；修复后两个传输路径均获得完整节点与分组，且通过真实内核校验。
- 基础回归 44 项、真实内核集成 45 项全部通过。
- 用户真实订阅：23 节点，3 个源策略组，无缺失引用；4 个日本节点抽测全部成功，手动选择与恢复自动选择通过。内核另有 GLOBAL 组，不计入源策略组。
- `/Applications/LumaRoute.app` 构建号 3 已安装，管理员后台服务快照已同步，保留新图标。
- 已从原生界面成功导入“新订阅”，随后更新成功，验证钥匙串地址读取及上次有效配置备份。
- 原订阅、活动配置、其余数据库字段及系统代理均与操作前一致。概览确认原东京节点保留，系统代理和 TUN 均关闭，内核及后台服务正常。

诊断仅保存脱敏结构和测试结果；临时订阅链接及响应副本已清理。用户导入的正式配置及钥匙串订阅地址正常保留。
