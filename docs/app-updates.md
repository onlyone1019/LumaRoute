# 应用内更新

0.1.8 / Build 38 使用 Sparkle 2.10.0，支持手动检查、下载、安装并自动重新启动。现有设置页、应用菜单、菜单栏的检查更新入口保持原位置；更新确认、进度和错误窗口使用 Sparkle 原生界面。不启用后台检查、自动下载、静默安装或系统信息上报。

## 安装与配置保留

下载和解压校验期间不关闭网络。用户确认安装后，应用会阻止新操作，等待正在进行的状态刷新结束，保存一次性的重启状态，再等待后台服务恢复系统网络并退出内核。恢复失败时拒绝退出，用户可在更新窗口重试。Sparkle 在应用退出后替换应用包并重新打开。

SQLite 数据、订阅内容、规则、策略和已保存的节点选择均在应用包外，更新流程不重写这些业务数据。一次性重启状态仅记录目标 Build、时间和系统代理/TUN 开关，权限为 0600；只接受一小时内与目标 Build 匹配的记录，读取后删除。正常启动仍遵循原来的“启动时连接”设置。

新版启动后若原有管理员服务需要同步，会自动进入既有系统授权流程。授权成功后按原配置继续连接；取消授权保留“完成更新”入口，不重复弹出授权、不清除业务配置。后台服务同步失败并不意味着应用包安装失败；原有服务安装器的回退机制继续保留。

应用替换、下载失败和签名错误由 Sparkle 处理。此实现没有增加“新版启动健康检查失败后自动降级”的功能，也没有改变现有 Developer ID / 公证状态。

## 签名与分发

- SwiftPM 精确锁定 Sparkle 2.10.0。构建脚本复制完整框架并保留符号链接、嵌套工具和许可；使用 Developer ID 构建时从内到外重新签名。
- 公钥位于 `Resources/Sparkle/public-key.txt`，构建时写入 `SUPublicEDKey`。当前私钥位于本机登录钥匙串中，账户名为 `app.lumaroute.desktop`，不进入仓库或安装包。
- 换机器发布前应安全迁移该签名密钥。上游工具支持 `generate_keys --account app.lumaroute.desktop -x /安全路径/密钥文件` 导出，以及 `-f` 导入。不要在已有发布用户时生成新密钥替换公钥。
- CI 可用 `LUMAROUTE_SPARKLE_KEY_FILE` 指定受保护的密钥文件；脚本不会打印私钥。打包会用应用内公钥校验生成的归档签名，密钥不匹配时中止。
- Intel 和 Apple Silicon 使用独立的 `appcast-x86_64.xml`、`appcast-arm64.xml`。更新源为本仓库 GitHub 最新正式 Release 的同名附件；归档来自该 Release 的对应架构 ZIP。
- 同时校验 appcast 签名、ZIP 的 EdDSA 签名和归档内代码签名；解压之前校验更新包。客户端额外限制下载来源、架构与递增 Build。

发布前将应用版本和 Build 更新为新值，Build 必须持续递增。按现有脚本构建两种架构，再打包：

```sh
# 示例版本，须与应用包中的版本一致；实际发布时使用对应的新版本。
LUMAROUTE_RELEASE_TAG=v0.1.8 ./script/package_release.sh dist/LumaRoute.app
LUMAROUTE_RELEASE_TAG=v0.1.8 ./script/package_release.sh dist/x86_64/LumaRoute.app
```

打包自动生成并签名对应架构的 appcast。若不指定 `LUMAROUTE_RELEASE_TAG`，使用 `v版本-build.Build`。发布到 GitHub 时，将两个 appcast 与两个架构的 ZIP、DMG、校验文件一同作为同一个正式 Release 的附件上传；不要先将缺少更新附件的 Release 设为 latest。构建和测试不会自动上传或发布。

0.1.7 及更早版本仍使用手动下载。首次安装 0.1.8 需要按原方式安装一次；已安装带 Sparkle 构建的用户可通过应用内更新升级到 Build 38。发布完整附件后，两个架构的最新更新源均指向 0.1.8。

## 验证

```sh
./script/build_and_run.sh --build-only
source script/build_environment.sh
swift test --configuration release --sdk "$SDK_PATH"
python3 -m unittest Tests.Scripts.test_version_metadata
python3 script/check_sparkle_update.py
python3 script/check_app_update_choices.py
```

更新验收使用真实 Sparkle、生产 AppUpdater/AppDelegate 和生产退出准备方法，在独立应用包之间进行下载、校验、替换及重新启动。源地址/架构策略保持生产实现，测试扩展仅将下载传输重定向到本地 HTTP 服务。后台服务和系统网络操作用 fixture 替换，测试不会更新当前安装的应用或管理员服务。检查成功重启、SQLite 配置保留、推迟更新、取消下载、归档被篡改、无新版本、恢复网络失败、错误架构、不可信下载源、未签名更新源和下载失败。

取消检查和更新源 HTTP 404 也包含在当前验收脚本中。取消检查在 Sparkle 中可能以无错误方式结束，不会调用 `didAbortWithError`；应用在 `didFinishUpdateCycleFor` 回收状态，避免按钮恢复可用后仍显示“正在检查更新…”。该问题先通过真实取消回调复现失败，再补结束回调并验证当前 12 组用例全部通过。已安装修复版也验证了真实更新源 404 后关闭错误窗口的状态回收。HTTP 404 代表当前正式 Release 尚未提供 appcast，不能当作“已是最新版本”或“线上升级已可用”。

应用声明简体中文语言，Sparkle 使用随框架提供的中文弹窗与按钮。设置页将更新错误转换为中文，区分更新源 404、更新包 404、网络超时、无法连接、校验失败和安装授权失败；不将失败误报为“已是最新版本”。404 提示为“更新源暂不可用（尚未发布或已移除），请稍后重试”。验收脚本同时验证 8 组中文错误映射和真实 HTTP 404 的最终提示。

本机已在备份后的安装环境中完成管理员服务同步及真实系统代理/TUN 恢复验收，见 [实机安装与恢复记录](app-update-live-acceptance-2026-10-17.md)。其他机器和 Intel 真机仍需独立验收；本地签名测试也不代表通过了 Developer ID、公证或浏览器下载后的 Gatekeeper 验收。

### 2026-10-17 本地结果

- Apple Silicon / Intel Release 构建与严格嵌套签名验证通过，分别嵌入对应架构的更新源。Intel 为交叉构建，未做 Intel 真机安装验收。
- 82 项 Swift 测试、29 项脚本测试、20 项窗口生命周期检查通过。
- 10 组真实 Sparkle 更新用例通过，包括自动替换及重新启动、取消、签名/来源/架构拒绝和网络恢复失败时阻止退出。更新后 SQLite 完整性正常，配置、订阅内容、测试控制密钥与节点选择保留。
- 生产 AppStore 的更新重启路径配合真实隔离 Mihomo，确认已保存的节点实际生效；系统代理/TUN 保持关闭，未访问已安装的管理员服务。
- 使用同一数据绘制更新前后的设置页，PNG 完全一致。双架构 ZIP、DMG 和已签名 appcast 生成通过；未上传 GitHub，也未替换当前安装的应用或后台服务。

以上为安装前的隔离验证。随后按用户授权完成实机安装和后台服务更新，结果见上述实机记录；上述验收时 GitHub Release 尚未发布；0.1.8 的发布说明见 [v0.1.8](releases/v0.1.8.md)。

参考：[Sparkle 接入文档](https://sparkle-project.org/documentation/)、[更新代理接口](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)。
