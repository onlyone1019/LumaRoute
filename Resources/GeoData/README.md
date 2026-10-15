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

最终整理已从原仓库可控分支和标签的可达历史中移除旧 GEO 输入。全部标签名称保留，Build 29 标签指向当前发布源码；原始历史及标签对象保存在仓库外备份中。GitHub 仍可能通过旧 SHA 或 PR 视图保留旧对象，强推不能证明服务端缓存已删除。仓库与备份继续保持私有。


## GeoLite 官方条款核对

MaxMind 官方帮助文档明确允许向组织外用户提供使用 GeoLite 数据的应用，前提是保留 MaxMind 署名；并不是只要使用 GeoLite 就必须购买商业许可。官方同时要求分发者向接收方传递相同或实质相同的条款，保持数据更新，并在新版发布后 30 天内删除旧版数据。不得用于定位具体个人、家庭或街道地址。

- 对外提供应用及署名：https://support.maxmind.com/knowledge-base/articles/sell-or-display-data-from-geolite-databases-and-web-services
- 适用对象及转交条款：https://support.maxmind.com/knowledge-base/articles/who-is-covered-by-the-geolite-end-user-license-agreement
- 更新及删除旧数据：https://support.maxmind.com/knowledge-base/articles/maintain-up-to-date-data
- 完整 GeoLite EULA：https://www.maxmind.com/en/geolite/eula

当前安装包及独立 GEO 附件已提供署名、CC BY-SA 正文、EULA 和来源说明。固定摘要用于构建完整性校验，不构成永久保留旧数据的额外授权；后续数据分发仍须按上述要求维护。本次确认的是官方公开条款，没有另行取得定制许可，也没有把人工维护表述为已实现自动清理。
