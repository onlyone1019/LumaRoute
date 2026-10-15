# GEO 数据版权、许可与来源

本声明适用于 `Resources/GeoData/release.json` 锁定的 2026-10-13 数据，以及从这些产物无损还原的规范化输入。LumaRoute 的根目录 MIT 不重新授权第三方规则、IP 数据或生成工具。版权属于下列作者及各项目贡献者；各许可按其适用材料分别保留，不能把整套聚合数据笼统标为 MIT 或仅标为 GPL。

## GeoIP / MetaDB

- 聚合及转换：[MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat/tree/4178770badecb1b349fbcd62c737e0d7a2079729)，GPL v3，正文见 `Meta-rules-dat-LICENSE`。上游工作流从 Loyalsoldier/geoip 获取完整 `geoip.dat`，转换生成 `geoip.metadb`。
- IP 数据：[Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip/tree/e25248cf0c91b54a853c9eb73c03c60c2ecc670f)，其 README 声明 CC BY-SA 4.0 与 GPL v3；数据许可正文见 `CC-BY-SA-4.0.txt`，工具 GPL 正文见 `Meta-rules-dat-LICENSE`。该项目使用 MaxMind GeoLite2 Country，替换中国大陆 IPv4 / IPv6 范围并加入运营商 / 服务分类。本项目继续保留这些声明，未直接使用 MaxMind 账户下载数据库。
- MaxMind, Inc.：

  This product includes GeoLite2 data created by MaxMind, available from https://www.maxmind.com.

  GeoLite 数据适用 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) 及 [GeoLite EULA](https://www.maxmind.com/en/geolite/eula)。随附 `MaxMind-GeoLite-EULA.txt` 为 2026-10-15 取得的正文（页面标注更新于 2026-02-12）。其署名、转交条款、数据更新和旧版本处置要求仍需遵守；补充署名不表示取得额外授权。
- 中国大陆 IP 范围：[gaoyifan/china-operator-ip](https://github.com/gaoyifan/china-operator-ip)，MIT，Copyright (c) 2017 Yifan Gao，正文见 `gaoyifan-china-operator-ip-LICENSE.txt`。其他服务分类来源见 Loyalsoldier/geoip 的上游配置和 README，不能仅凭聚合项目的许可替代原来源条款。

## GeoSite

下列来源由固定上游工作流使用。源码 checkout revision 和取得许可声明时的 revision 记录于 `GeoData-license-sources.json`；后者不冒充已丢失的动态数据下载 revision。

| 来源 / 作者 | 使用范围 | 保留的许可文件 |
| --- | --- | --- |
| [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community/tree/c6adacf29cc4fb05e04651fcf03e00989ef9f797)，Copyright (c) 2018-2019 V2Ray | 基础域名分类 | MIT，`v2fly-domain-list-community-LICENSE.txt` |
| [Loyalsoldier/domain-list-custom](https://github.com/Loyalsoldier/domain-list-custom/tree/efacb51b8950ae673ebb6dcb9e7ecdd1decb1b6d)，Copyright (c) 2020 Loyalsoldier | 自定义规则及生成程序 | MIT，`Loyalsoldier-domain-list-custom-LICENSE.txt` |
| [blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script) / blackmatrix7 与贡献者 | ChinaMax、SteamCN、OneDrive、PrivateTracker、BlockHttpDNS | 上游 GPL v2 正文，`blackmatrix7-ios_rule_script-LICENSE.txt` |
| [felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list)，Copyright © 2013 Felix Yan | Apple / Google 中国域名 | WTFPL v2，`felixonmars-dnsmasq-china-list-LICENSE.txt` |
| [crazy-max/WindowsSpyBlocker](https://github.com/crazy-max/WindowsSpyBlocker)，Copyright (c) 2016-2022 CrazyMax | win-spy、win-update、win-extra | MIT，`crazy-max-WindowsSpyBlocker-LICENSE.txt` |
| [gfwlist/gfwlist](https://github.com/gfwlist/gfwlist) / GFWList contributors | 代理域名输入 | LGPL v2.1 正文，`gfwlist-gfwlist-LICENSE.txt` |
| [cokebar/gfwlist2dnsmasq](https://github.com/cokebar/gfwlist2dnsmasq/tree/202e52fb5ea2260abc9f162b3a78e58ec9187005) / cokebar 与贡献者 | GFWList 转换工具，未链接到应用 | GPL v3，`cokebar-gfwlist2dnsmasq-LICENSE.txt` |
| [XIU2/TrackersListCollection](https://github.com/XIU2/TrackersListCollection) / XIU2 与贡献者 | tracker 域名输入（上游从其 Gitea 镜像下载） | GPL v3，`XIU2-TrackersListCollection-LICENSE.txt` |
| [xishang0128/rules](https://github.com/xishang0128/rules/tree/8b05b32709735c98c6b2f0d3a00e8ed1fcbc7800) / xishang0128 | biliintl、sharepoint | 检查到的 revision 无 LICENSE，README 未授予明确再分发许可；保留来源署名不等于取得授权。对外公开前仍须确认授权，或另行审阅并替换这部分规则。 |

## 修改、源码与证据边界

上游对域名进行了聚合、过滤、去重、分类覆盖和格式转换；具体步骤见随源保存的 `upstream-workflow.yml`。LumaRoute 将发布数据反向导出为可编辑 JSON，保留规则顺序、匹配类型、属性、CIDR、反向匹配标志及原 MetaDB 时间戳；未改变规则语义。三份数据的逐字节重建 SHA-256 见锁定清单。

规范化 JSON 继承对应数据的许可；其中的 CC BY-SA 材料及其改编按 CC BY-SA 4.0 提供。不能借由换格式去除署名或施加不兼容限制。完整可编辑输入、固定 GPL 重建工具、vendored 依赖与各自许可随 GEO 源码附件提供；Mihomo、Yams 的对应源码另附于 Release。

上游未归档全部原始网络响应；本声明不是完整权利链证明。未声明许可的输入以及 GeoLite EULA 对持续分发和旧数据处置的要求，不能通过保留一个固定快照自动解决。仓库目前保持私有；将来公开前仍需处理上述未明确授权的输入及数据维护方式。

本次仅补充许可、署名和来源记录；GEO 数据、规范化 JSON 与锁定摘要均未修改。
