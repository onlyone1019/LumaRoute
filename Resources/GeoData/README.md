# GEO 数据独立分发

源码 Git 只保留 `release.json` 中的版本、SHA-256、独立附件地址及构建脚本。三份 GEO 数据、完整规范化输入、捕获的原始规则、生成策略及 GPL 重建工具不再提交到当前源码树。

完整材料放在 Build 29 的独立附件 `LumaRoute-GEO-inputs-2026-10-15-licensed-rules.tar.gz`。其中包含可编辑输入、固定工具、vendored 依赖、原始许可证和来源说明；它与应用源码附件分别提供。下载摘要固定在 `release.json`，不会静默换用上游滚动 `latest` 数据。

```sh
python3 script/fetch_geodata.py
```

构建脚本会自动执行以上步骤：取得独立附件，校验完整 SHA-256，临时解包并验证来源 / 许可证 / 在线更新策略，然后验证已有数据或离线重建三份文件。只有校验后的数据和策略才复制进应用包，输入和工具在操作结束后删除，归档缓存放在被 Git 忽略的 `work/geodata-cache/`。

仓库私有期间，需要提供具备本仓库读取权限的 `GH_TOKEN`（CI 自动提供），或先从 Release 下载附件并指定本地路径：

```sh
export LUMAROUTE_GEO_SOURCE_ARCHIVE=/path/to/LumaRoute-GEO-inputs-2026-10-15-licensed-rules.tar.gz
python3 script/fetch_geodata.py
python3 script/rebuild_geodata.py --output work/geodata-rebuilt
```

预先取得附件后，重建使用本机 Go、空模块缓存和完整 vendored 依赖，不下载 Go 模块或工具链。独立附件自身也可解包后直接运行其中的 `python3 script/rebuild_geodata.py --output rebuilt`，不依赖本仓库。

应用内手动在线更新及旧快照回退继续应用固定的 biliintl / sharepoint 许可策略；本次管理方式调整不改变现有匹配结果。数据仍按各来源许可提供，不能因未提交 Git 就视为 MIT，也不免除 GeoLite 等适用条款。见 [GEO 专项声明](../Licenses/GeoData-NOTICE.md)。

既有 Git 标签与历史按维护者要求保留，因此仍能找到此前提交过的输入和工具；这是从当前版本开始分离管理，没有重写历史，也不表示历史材料取得额外授权。仓库和已有外部备份继续保持私有。
