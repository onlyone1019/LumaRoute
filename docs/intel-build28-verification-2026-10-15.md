# Build 28 Intel 安装包验证

日期：2026-10-15。源码基线：Build 28 标签 `eecb12b85a6a6aa5db35bc2387fae674fe4c1641`。本次只调整构建、打包脚本和文档，应用功能源码保持标签版本。

## 构建

使用 Apple Silicon Mac、Swift 6.4、macOS 26.5 SDK，交叉编译 `x86_64-apple-macosx14.0`，独立编译目录 `.build/x86_64`。内核为已锁定并验证原始二进制校验值的 Mihomo v1.19.32 `darwin-amd64-compatible`，随应用进行 ad-hoc 签名。

```sh
LUMAROUTE_ARCH=x86_64 ./script/build_and_run.sh --build-only
./script/package_release.sh dist/x86_64/LumaRoute.app
```

主程序和后台服务的 Mach-O `minos` 均为 14.0；内核为 10.13，应用整体要求 macOS 14+。所有嵌入可执行文件均为单一 `x86_64` 架构，动态库依赖限于系统路径。保留本地原 ARM 应用和已发布 ARM 附件。

## 已完成

| 检查 | 结果 |
| --- | --- |
| 安装包中的主程序 | Rosetta 下启动、独立 SQLite 初始化、正常退出通过 |
| 后台服务可执行文件 | 正常加载并拒绝非管理员运行 |
| CLI 核心回归 | 218 项通过；验证 CLI 单独补充 ad-hoc 签名后执行身份校验 |
| 真实 Mihomo 核心冒烟 | 版本、代理、连接、规则、模式及节点选择通过 |
| 真实内核集成 | 79 项通过 |
| 多订阅组合 | 15 项通过 |
| 非进程分流 | 8 项通过，包含域名、IPv4 / IPv6、策略组、直连、拒绝和停用 |
| 成员节点 DNS | 3 项通过 |
| 规则热更新 | 15 项通过 |
| 实际 AppStore / SQLite | 9 项通过 |
| 原生界面 / 刷新 / 缓存 | x86_64 宿主在 Rosetta 下 41 项通过，并检查概览截图 |
| 安装包完整性 | DMG 镜像校验 / 挂载、ZIP 解压、版本、架构、签名、权限与源应用逐文件 SHA-256 一致 |
| 校验清单 | 四个安装包校验通过，原 ARM 的两条 SHA-256 保持不变 |

测试使用独立目录、合成数据和 loopback 服务；未接管系统代理或 TUN，未替换在线应用或已授权后台服务。构建产生的 CLT 缺失搜索目录警告未阻止链接，安装包动态依赖检查与实际启动通过。

## 未通过或尚未验证

原始 `composition-routing-check` 在按进程名匹配处失败。最小对照保持配置和请求不变，只替换 ARM / x86_64 内核，两者在非管理员环境均报 `process not found` 并进入兜底出口。该结果不能归因于 Intel 架构，也不能证明管理员后台服务场景可用。未获取管理员授权，未将进程匹配计为通过。另行复用同一专项的非进程规则完成其余八项检查，原失败日志保留。

未执行 Intel 真机、完整 TUN 接管、首次安装授权、登录自启、物理断网或 XCTest 验收。Rosetta 测试不能替代 Intel 真机测试。安装包继续使用 ad-hoc 签名，未使用 Developer ID 或 Apple 公证。

## Intel 文件校验

```text
305a84e5dee3772125eec5ab6f3d9844b682495d02e17cd09118123fb97383c3  LumaRoute-0.1.0-build.28-macos-x86_64.dmg
1766b84eb36a76c70d0650d31df33064be4728dde559a457d037401ed8b8a20e  LumaRoute-0.1.0-build.28-macos-x86_64.zip
```

本地证据位于忽略目录 `work/intel-build28-verification/`，包含测试输出、界面截图、最小对照日志、包内文件清单和 Mach-O 加载命令。私有测试目录不随安装包或 Release 上传。

## GitHub 发布复核

已补充至 [Build 28 Release](https://github.com/onlyone1019/LumaRoute/releases/tag/v0.1.0-build.28)，并更新发布说明和合并校验清单。发布附件共五个：ARM / Intel 各一份 DMG、ZIP，加一份校验文件。

GitHub 返回的五个附件 SHA-256 均与本地一致；原 ARM 两个附件的 ID 和摘要保持不变，标签源码未移动。已重新下载 Intel DMG、ZIP 与 `SHA256SUMS.txt`，逐一核对与本地文件完全一致。仓库为私有仓库，下载需要具有访问权限的 GitHub 账号。
