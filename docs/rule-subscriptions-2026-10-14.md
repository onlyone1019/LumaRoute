# 第 17 版：Loyalsoldier 规则订阅

## 使用

进入“规则 → 规则订阅 → 添加规则订阅”，选择规则集、目标策略和更新周期。当前内置 [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) 发布分支提供的 13 个规则集；域名集使用 domain，IP 集使用 ipcidr，applications 使用 classical，文件格式均为 YAML。

默认自动更新周期为 24 小时，可选 1、6、12、24、48、168 小时。应用运行且内核就绪时检查到期任务；退出、休眠期间不执行，恢复后补做已到期任务。失败以最近尝试时间计算下一周期，不持续高频重试；也可以手动更新单项或当前机场的全部规则集。

规则订阅绑定当前机场配置。选择直连、拦截，或该机场现有的策略组。切换机场不会把另一机场的映射套过来；机场更新删除或改名目标组时，仅暂停对应规则订阅并显示提示，机场配置仍可正常加载。

默认不自动添加任何规则集。建议先按需要逐项添加，避免把范围很广的列表一并启用。

## 保留机场分流

运行时顺序：

1. 手工自定义规则。
2. 显式选择“优先于机场规则”的规则订阅。
3. 机场原有规则。
4. 默认“补充机场规则”的规则订阅。
5. 机场首个 MATCH / FINAL 兜底及之后的原规则。

机场原有规则和策略组内容、相对顺序均保留；只向运行配置插入独立的规则提供器和 RULE-SET 引用，不改写机场原始 YAML。补充模式不会覆盖机场已经命中的业务分流。要让广告拦截等先于机场分流生效，需主动选择优先模式，设置页会说明覆盖影响。全局和直连模式依然由 Mihomo 的模式控制，规则模式下才按上述分流规则执行。

同一优先级按照列表顺序匹配，可通过“更多 → 上移 / 下移”调整。生成的提供器名称和文件路径独立；遇到机场提供器同名时另取名称，不覆盖机场定义。

## 更新与恢复

下载优先使用遵循当前系统代理的临时 URLSession；发生传输错误时尝试直连。HTTPS 继续验证证书；每个规则集上限 8 MB，当前启用规则集总量上限 32 MB。只接受内置仓库目录中的条目。

更新流程为下载、检查 payload、独立无特权内核加载校验、保存不可变缓存版本、加载完整运行配置、持久化元数据。Mihomo `-t` 可能只检查配置结构，不能据此断言规则文件已解析；独立校验会实际启动仅监听回环地址的临时内核，并确认规则提供器非空。完整运行配置加载后再次核对受管理规则集已加载。

下载、校验、加载或保存失败时保留原缓存和原配置。自动更新失败在列表显示原因与上次成功时间。备份包含规则缓存，恢复不需要重新联网下载；删除前自动备份，删除后原机场分流保留。更新成功后清理不再引用的本机缓存，历史备份独立保留。

后台服务接收规则内容，不接收调用者指定的本机文件路径；它在自己的配置目录生成只读规则输入，仍由原服务负责管理内核和网络设置。

配置格式与匹配顺序依据：[Mihomo 规则集](https://github.com/metacubex/meta-docs/blob/main/docs/config/rule-providers/index.md)、[规则内容格式](https://github.com/metacubex/meta-docs/blob/main/docs/config/rule-providers/content.md)、[路由规则](https://github.com/metacubex/meta-docs/blob/main/docs/config/rules/index.md)。

## 验证

- Release 构建、严格包签名校验通过，应用与后台服务均为第 17 版。
- CLI 原生回归 56 项通过。
- 新增 `rule-catalog-check` 37 项集成检查通过，包括真实 HTTP 请求证明机场原规则优先、补充规则接管未匹配流量、显式优先覆盖、手工规则更优先、停用恢复、目标组缺失、不同机场隔离、HTTP/格式错误、真实内核拒绝损坏内容、备份恢复、协议传输、调度和名称碰撞。
- 上述检查逐个从官方地址下载并实际加载全部 13 个规则集，均通过。
- `script/check_rule_subscription_store.py` 编译实际 AppStore：到期下载并提交、未到期不重复更新、关闭自动更新跳过、元数据与缓存持久化，4 项通过。使用隔离数据目录和无特权校验内核，不读取用户钥匙串或修改系统代理。
- 实际 AppStore 测速回归：10 轮 × 64 节点、取消、立即重测、空批次通过。
- 实际 GUI：添加 iCloud（53 条）、选择机场现有 US-Residential 策略组并保存、单项更新、停用、重新启用、删除；独立查询管理员内核确认 File / Domain 规则提供器加载 53 条，停用后为 0。界面截图已目视核对。
- 安装同步前先恢复网络再维护服务；Clash Verge 在维护期间占用了 7890，恢复原端口时应用正确拒绝冲突并保留可用配置。用户最终明确选择保持 LumaRoute 的 19790 系统代理，TUN 保持关闭。测试规则集删除，原机场 YAML / previous 文件校验值不变；数据库除新增空规则订阅字段及经用户确认的代理端口调整外保持原值。

原始私有证据位于 `work/rule-subscriptions-2026-10-14/`，含旧包、构建、调度和集成日志及前后校验快照，不打包分发。自动更新已通过调用实际到期调度函数验证，本轮未等待完整 24 小时。

复现命令（先启动 `python3 script/local_fixture.py`）：

```sh
bash script/build_and_run.sh --build-only
.build/out/Products/Release/LumaRouteCLI verify
.build/out/Products/Release/LumaRouteCLI rule-catalog-check Resources/Core/mihomo-arm64 work/rule-subscription-check
python3 script/check_rule_subscription_store.py
python3 script/check_latency_batch.py
```
