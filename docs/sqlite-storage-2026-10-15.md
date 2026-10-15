# Build 21：应用业务数据统一到 SQLite

默认数据库为 `~/Library/Application Support/LumaRoute/lumaroute.sqlite`，本机路径为 `~/Library/Application Support/LumaRoute/lumaroute.sqlite`。数据目录权限为 `0700`，数据库为 `0600`。继续支持 `LUMAROUTE_DATA_DIR`，用于隔离测试数据。

按本次要求，新库从空状态开始，不迁移旧业务 JSON、订阅文件和钥匙串记录。旧数据原样保留。应用已移除钥匙串的 `SecItem` 调用，控制接口密钥及完整订阅链接均通过 SQLite 读写。

## 存储内容

| 表 | 内容 |
| --- | --- |
| app_state | 设置、活动订阅及可选集合状态 |
| profiles | 订阅元数据及显示顺序 |
| profile_contents | 订阅原始内容的 current / previous 版本 |
| custom_rules | 自定义规则及顺序 |
| group_strategies | 分组策略及顺序 |
| rule_subscriptions / rule_contents | 规则订阅元数据及规则原文 |
| choices | 用户保存的节点选择 |
| secrets | 控制接口密钥及完整订阅链接 |

结构化记录沿用现有 Codable 模型，在对应表的 payload 列保存序列化数据；订阅与规则原文独立存储。上层 AppStore 使用既有业务模型。使用系统 SQLite3，无额外 ORM 或第三方数据库依赖。

内核可执行文件、GeoData、运行 YAML、provider 文件、内核版本及进程恢复记录、管理员服务授权和系统网络恢复记录继续使用其原有文件。内核运行时从业务数据生成所需配置，root helper 不直接访问普通用户业务数据库。

## 一致性与备份

- 设置及相关集合在一次事务中保存。订阅导入同时提交内容、元数据和完整链接；删除同时移除元数据、当前/历史内容及对应链接。
- 规则更新先校验并应用候选内容，再以事务提交新内容和元数据；失败保留原数据，并沿用内核回滚流程。
- SQLite 连接使用 FULLMUTEX 和覆盖整笔事务的递归锁，避免后台密钥读取进入未完成的事务；锁等待有上限，错误信息不打印绑定值或 SQLite 详细凭据。
- 采用 DELETE journal 模式，提交完成后主要保留一个数据库文件。启用 secure_delete，密钥删除后不回退读取旧存储。数据库为普通 SQLite，未声称其加密或具有钥匙串级隔离。
- schema 使用 user_version=1。损坏文件或未知版本报错并保留原文件，不删除或重建为新库。
- 普通备份通过一致性读事务导出筛选过的 SQLite 数据，排除 secrets 表中的链接和控制密钥；在临时目录完成后发布备份目录，不直接复制运行中的数据库。
- 恢复选择包含 lumaroute.sqlite 的新版备份目录，校验订阅和规则内容，再提交恢复数据；本机密钥继续保留。此次没有旧格式导入或旧备份迁移。
- 数据库事务仅覆盖业务存储，内核及系统网络操作仍使用已有的校验、回滚和独立恢复记录。

## 验证结果

- Release 构建、深度严格签名通过；Build 21 安装到 `/Applications/LumaRoute/LumaRoute.app`，名称保持 LumaRoute。
- 电脑操作工具禁止操作 SecurityAgent。本次在用户授权下通过终端的管理员验证执行既有服务安装器，服务自动检测更新并恢复内核。密码未写入代码、脚本、数据库或测试日志。
- `LumaRouteCLI verify`：122 项原生回归通过，其中 20 项覆盖 SQLite 空启动、旧文件保留、全业务数据重开、文件权限、字符和空值、事务末尾故障回滚、备份筛选与恢复、删除、损坏文件及未知版本拒绝。
- `LumaRouteCLI rule-subscription-check`：24 项真实 Mihomo 回环集成检查通过，包含原规则优先级、候选失败保留、规则内容备份与恢复。
- `check_rule_subscription_store.py`：实际 AppStore 到期调度下载并提交、未到期跳过、关闭自动更新及内容/元数据持久化通过。
- `check_preferences_refresh.py`：普通设置独立保存约 9 ms；保存失败保持现有设置。隐藏窗口 60 秒虚拟调度中的 HTTP 请求仍为 38 次，代理页 62、连接页 68、规则页 40，保留 30 次控制接口健康检查。
- `check_latency_batch.py`：10 轮 64 节点批量测速、失败、取消、重启及空批次通过。
- 真实安装版从空库导入本机 HTTP fixture，更新成功；SQLite 中包含元数据、current/previous 内容及订阅 URL，控制接口使用新库中的密钥完成认证。
- 实际切换节点并将测试并发从 6 改为 7，重开后订阅、节点和设置保留。普通设置界面单次保存约 506 ms，包含自动化开销，不重新加载配置。
- 实际创建的 SQLite 备份不含密钥；将并发改为 8 后，通过原生文件夹选择器恢复为 7。控制密钥、完整订阅链接和节点选择保持一致，真实代理回环请求返回预期大阪路由。
- 同版本正常重开未重新安装服务，授权 metadata 哈希及修改时间未变，没有钥匙串访问提示。
- 测试结束后清理测试订阅和选择，恢复初始空库，保留本机新生成的控制密钥。全部 106 个旧业务文件哈希保持一致，系统代理保持测试前状态；数据库 integrity_check 为 ok。
- 当前 CLT 缺少 XCTest，使用原生 CLI 和实际 AppStore/安装版验证。此次未新增真实 TUN 开启验收、旧格式迁移或加密数据库测试。

测试产物与旧 Build 20 备份位于 `work/sqlite-2026-10-15/`，包含私有数据库快照，仅用于本机核对，不提交到仓库。
