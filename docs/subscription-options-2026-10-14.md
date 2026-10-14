# 独立 User-Agent 与订阅错误提示验收

## 实现范围

参考 Clash Verge Rev 的按订阅保存 `user_agent` 选项的方式。对照源码 commit `5b10331022940dfbd049adfa6f714d3da2d5a6ef` 的 `src-tauri/src/config/prfitem.rs` 与 `src-tauri/src/utils/network.rs`，并通过 Context7 核对其配置模型及远程导入处理。

- Profile 新增可选 `userAgent`，缺少字段的旧配置继续读取并沿用默认值。
- 添加订阅时可以填写 User-Agent；已有远程订阅从“更多 → 订阅设置”修改、保存或恢复默认。保存设置不触发网络接管，下次更新使用新标识。
- 导入、手动更新、更新全部及定时更新都读取该订阅的选项。URLSession 与直连 curl 使用相同的输入；curl 配置中的引号和反斜杠独立转义。
- 只接受单行可见 ASCII 字符，最多 512 字节；空值恢复默认，不自动轮换或猜测客户端标识。
- 明确区分地址、请求头、网络连接、HTTP 状态、网页响应、空响应、过大内容、编码、订阅格式、内核配置校验错误。HTTP 401/403、404、429、5xx 有对应建议。
- 不展示响应正文和订阅凭据；内核详情脱敏并限制长度。失败的导入保留表单供修改重试，失败的更新保留上次可用配置。

## 自动检查

- `LumaRouteCLI verify`：53 项基础检查通过，包括旧 Profile 读取、多订阅独立存储、非法标识拒绝及错误详情脱敏。
- `LumaRouteCLI fixture-check`：79 项真实内核集成检查通过。新增两种传输的独立标识、带引号/反斜杠标识、默认恢复、HTTP 状态、HTML/JSON/错误 YAML、空响应、编码、8 MB 限制、BOM、连接失败及自定义标识返回的配置校验。
- 完整构建与 `codesign --verify --deep --strict` 通过。

## 已安装版本原生界面检查

所有新增的失败请求均使用无凭据的回环 fixture，没有修改真实订阅地址或切换真实活动配置。

1. 添加订阅表单展示 User-Agent 和默认值。HTTP 403、HTML 网页及真实内核的缺失组错误均有不同提示，原填写内容保留；失败后数据库与操作前完全相同。
2. 同一表单改为 fixture 要求的自定义标识后重试成功，导入 3 个测试节点；手动更新成功，证明设置参与实际请求。
3. 从该订阅的“更多 → 订阅设置”打开并读回标识。非法字符被明确拒绝；恢复默认、保存成功且不影响其他订阅。
4. 使用默认标识更新专用 fixture，真实内核拒绝不完整配置；原节点数及有效 YAML 的 SHA256 保持不变。
5. 通过界面重新保存正确标识后退出应用，仅将该临时测试订阅的更新时间标记为到期。重启安装版后，实际定时更新成功，错误清除；证明设置跨重启保留并用于自动更新。
6. 经界面删除临时测试订阅，配置文件及前一版本文件清理成功；停止本次专用 fixture 服务。

界面证据：`work/subscription-options-2026-10-14/import-http-error.png`、`import-config-error.png`、`subscription-options.png`。其中 HTTP 错误页已做视觉检查。

## 安装与最终状态

- 已安装 `/Applications/LumaRoute.app`，版本 `0.1.0`，构建号 `4`。新图标内容保持一致，旧应用包保留在本次 work 目录中以便回退。
- 本机管理员服务的 GUI、helper、图标快照与已安装应用匹配；继续使用免费 ad-hoc 签名。
- 应用从“应用程序”启动，后台服务及内核正常；系统代理和 TUN 均关闭，原东京节点保留。
- 清理测试订阅后，数据库、两条真实订阅的 YAML 内容及系统代理与本次操作前一致；其他软件的内核未操作。
- 证明文件：`work/subscription-options-2026-10-14/final-verification.json`、`automatic-update.json`、`ui-update-failure.json`、`installation.json`、`service-sync.json` 及两份检查日志。

本次功能不代表覆盖所有服务商；不兼容时可按服务商要求独立设置标识，并依据错误阶段排查。
