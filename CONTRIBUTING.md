# 参与 LumaRoute

欢迎提交 Bug 报告、文档修正和范围清晰的 Pull Request。安全问题请先阅读 [SECURITY.md](SECURITY.md)。

## 开发与验证

需要 macOS 14+、Swift 工具链、Python 3 和 Go 1.23+。按 [README](README.md) 构建；只构建使用 `./script/build_and_run.sh --build-only`，避免退出正在运行的应用。完整 Xcode 环境可运行 `swift test`；仅有 CLT 时，XCTest 是否可用取决于本机工具链。

PR 请说明解决的问题、变化后的行为、实际执行的检查及尚未验证的内容。涉及管理员服务、网络接管、存储或恢复逻辑时，说明失败时的回滚行为。自动化检查不代表真实订阅、首次授权或 TUN 已通过验收。

测试应使用合成配置、loopback 服务和独立 `LUMAROUTE_DATA_DIR`。不要提交真实订阅、节点凭据、用户数据库、私有运行快照、证书私钥或个人机器路径。提交前检查 diff 和 Git 历史中的新内容。

## 许可与素材

你提交的自有贡献按项目 MIT 协议提供；第三方代码和资源必须注明来源，并保留许可和版权。请确认你有权提交这些内容。不要为了规避检测而掩盖秘密扫描告警。

新图标优先采用自行创作或有清晰授权的素材；使用生成工具时记录工具、提示和参考素材来源。不要直接复制其他应用标志。第三方组件范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
