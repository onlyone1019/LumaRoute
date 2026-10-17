# 持久化兼容样本

`v1/` 是手写并冻结的最小字段兼容契约，使用合成数据，不对应某个已发布应用版本或用户数据库。日期沿用 JSONEncoder 默认的 Apple reference date 数值格式。

- `database.json` 覆盖设置、订阅、用量、变化摘要、规则、策略、组合和规则订阅，故意省略可默认的字段。
- `sqlite-state.json` 是 SQLite `app_state.payload`，保留两个功能标记，测试关系记录完整读取。
- `sqlite-state-minimal.json` 覆盖缺少设置和功能标记的情况；标记默认 false，保留未配置和空列表的原有区别。

回归测试直接读取这些文件，并将原始 JSON 片段写入临时 SQLite；不能用当前模型的编码结果重建样本。后续扩展应保留 v1 文件，新增版本目录。
