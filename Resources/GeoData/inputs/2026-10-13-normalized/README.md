# GEO 规范化生成输入快照

对应现有 2026-10-13 GEO 数据。此快照包含可以编辑的 CIDR 和域名规则输入，不是把产物转成 base64 保存，也不是声称追回了当时所有上游 HTTP 响应。

- `geoip.json.gz`：260 个国家 / 分类的 CIDR、顺序及反向匹配标志。解压后是普通 JSON，IP 使用可读的 IPv4 / IPv6 前缀字符串。
- `geosite.json.gz`：1,555 个域名分类、每项匹配类型、值、属性及其类型和顺序。解压后是普通 JSON。
- `manifest.json`：格式、原始 MetaDB 构建时间和三份目标产物的 SHA-256。
- `metadb-metadata.json`：原 MetaDB 元数据。
- `provenance.json`：原始构建记录、从原日志取得的仓库 revision、生成工具固定版本，以及规范化快照的证据边界。
- `upstream-workflow.yml`：固定上游 revision 的构建步骤，仅作来源记录，不是本项目的自动执行工作流。

## 离线重建

需要 Go 1.23+ 和 Python 3；Go 工具及其依赖源码均位于 `tools/geodata-snapshot/`，无须下载模块或访问最新规则服务。

```sh
python3 script/rebuild_geodata.py --output work/geodata-rebuilt
```

脚本使用 `-mod=vendor`、空模块缓存和 `GOPROXY=off` / `GOSUMDB=off` / `GOTOOLCHAIN=local`。只有三份重建结果都通过锁定 SHA-256 检查后才写入目标目录。完整重建得到与既有发布包逐字节相同的 `GeoIP.dat`、`GeoSite.dat`、`geoip.metadb`。

编辑输入时先解压为 JSON，修改后重新压缩。对已发布快照不要原地改写；应创建新的日期目录、重新生成清单并完成规则与网络行为验证。目标摘要校验用于验证现有快照；有意变更输入时，需要单独审阅并更新目标版本及摘要。

## 许可与来源边界

GEO 数据继承上游组件和原始数据来源的许可，不能作为 LumaRoute 自有 MIT 数据重新授权。参见 `THIRD_PARTY_NOTICES.md`、`Resources/Licenses/Meta-rules-dat-LICENSE` 与上游来源 README。生成工具及所用 GPL 组件的许可、修改说明和依赖许可证随源码保留。

原始上游构建未保存输入附件，部分动态网络输入无法重新取得。这份快照是从已发布产物无损还原的规范化、可编辑生成输入；它保留重建所需的全部规则、顺序、属性和元数据，三份结果已逐字节核对。它不伪装为原始采集档案，也不能独自证明每个上游数据源的权利链。
