# 固定 GEO 数据重建工具

本工具与 Swift 应用分开构建，采用 GNU GPL v3，见本目录 `LICENSE`。它使用 MetaCubeX/geo 固定 revision `a4db326ccfd7e21276d5d05f4f7e512d14415553` 的 protobuf 模型；`metadb.go` 基于该 revision 的 `convert/v2ray_ip.go`，唯一格式相关改动是显式传入原始 MetaDB 构建时间，消除当前时间对产物的影响。

`main.go` 将规则导出成可读的 CIDR / 域名 JSON，再还原 protobuf。拒绝无法识别的扩展字段、域名类型和属性，避免静默丢失数据。输入没有规则凭据，也不会访问用户数据库、订阅或在线代理。

所有运行时依赖已 vendoring，`go.mod`、`go.sum`、`vendor/modules.txt` 与各上游许可证一并保留。不要将本目录或第三方依赖标为应用的 MIT 自有代码。

```sh
cd tools/geodata-snapshot
GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local go build -mod=vendor -trimpath -o ../../work/geodata-snapshot .
cd ../..
work/geodata-snapshot rebuild Resources/GeoData/inputs/2026-10-13-normalized work/geodata-rebuilt
```

从现有数据建立新的审计快照可使用 `dump <existing-data-dir> <snapshot-dir>`。`rebuild` 必须对全部三份目标 SHA-256 校验通过才成功；项目通常通过 `script/rebuild_geodata.py` 在临时目录生成、复核，再写入输出。
