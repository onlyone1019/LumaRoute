# 聚合后 sakuran 节点全部测速失败（Build 25 修复）

## 现象与复现

2026-10-15，sakuran 单独启用可测速，加入以另一订阅为基础的组合后节点全部失败。现有组合保持启用，使用缓存订阅和独立端口建立对照，未下载、改写订阅或打开系统代理/TUN。

`work/composition-sakuran-2026-10-15/repro` 首次对照：同样三个香港节点单独运行分别返回 37–45 ms，聚合后三个均失败；真实运行内核的节点测速接口返回 HTTP 503。

进一步控制变量：

- 合并前后节点参数只有 `name` 变化；单独给节点加相同前缀仍可测速，排除名称及测速接口问题。
- 只替换聚合配置的 `proxy-server-nameserver` 即恢复；分别替换 `nameserver`、`nameserver-policy`、`default-nameserver`、`use-hosts` 均不能恢复。

根因是合并只保留了基础订阅 DNS，丢弃了成员自身的节点服务器解析配置。单订阅和组合因此对相同节点服务器使用了不同解析器。

## 修复

`CompositionComposer` 为非基础成员中直接声明的域名节点生成精确的 `proxy-server-nameserver-policy`，使用该成员显式的 `proxy-server-nameserver`。基础订阅的网站 DNS、分流规则保持原有选择。

`CompositionNodeDNS` 负责收集和匹配：支持成员节点 DNS 的精确域名及常见后缀策略；DNS URL 中的策略组出口继续按来源重命名；同域名冲突时基础订阅的策略优先，不受勾选顺序影响。IP 地址节点不会生成不必要的域名策略。

该内核选项及启用条件参考 [Mihomo DNS 文档](https://wiki.metacubex.one/config/dns/#proxy-server-nameserver-policy)：节点解析策略要求 `proxy-server-nameserver` 非空。生成成员策略时会保证这一条件，避免生成有效但不生效的字段。

修复作用于配置中已声明的节点及显式节点 DNS，不会为 provider 服务器尚未返回的动态节点凭空推断域名或解析器。

## 回归和实际验收

新增 `LumaRouteCLI composition-dns-check <core> <workdir>`，使用两个回环 DNS 服务：基础 DNS 对 B 的节点域名返回 NXDOMAIN，B 的 DNS 返回正确回环地址。修复前 B 单独测速成功，聚合时明确失败；修复后两者均通过。

| 检查 | 结果 |
| --- | --- |
| 新增 DNS 集成检查 | 3 项通过：B 单独可测、聚合 B 可测、基础 A 仍可测 |
| 原生回归 | 171 项断言通过，含 4 项 DNS 保留、来源引用、后缀策略和同域名优先级检查 |
| 既有多订阅真实内核检查 | 15 项通过 |
| 实际 AppStore 检查 | 6 项通过 |
| 原始 sakuran 复现脚本 | 单独及聚合均测速成功 |
| 已安装 Build 25 应用内点击“测速 聚合节点” | 完成 26/26，sakuran 25 个条目全部返回正延迟，原基础订阅节点也可用 |
| 应用包与后台服务 | dist、已安装包和服务副本的全部文件哈希一致，均通过 deep/strict 验签 |
| 用户业务数据 | 逐表规范化后与修复前完全一致，SQLite integrity_check 为 ok；当前组合和网络开关保持原状态 |

例如此次应用内测速香港节点返回 171 ms、东京节点返回 311 ms；具体延迟随线路和 DNS 缓存变化，这些结果只证明本次请求能够通过相应节点完成。

Build 25 已安装到 `/Applications/LumaRoute/LumaRoute.app`，无需删除或重建现有组合。本次未提交推送或发布 Release。CLT 环境使用 CLI、真实内核及 AppStore harness 验收，未执行 XCTest。

含订阅缓存的数据库快照、隔离复现程序和旧 Build 24 包保存在 Git 忽略的私有目录 `work/composition-sakuran-2026-10-15/`，不应上传。日志只打印诊断所需字段及节点名称，不输出订阅链接或凭据。
