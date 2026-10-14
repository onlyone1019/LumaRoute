# 第 14 版本机验证

## Dock 显示

原安装路径 `/Applications/LumaRoute.app` 在主窗口显示、应用返回 regular 激活状态时仍没有 Dock 项，用户多次确认。因此不能仅用激活策略调用成功作为验收依据。

保持二进制、Info.plist、图标、签名和真实数据不变的路径对照：

| 启动位置 | 用户观察 |
| --- | --- |
| `/Applications/LumaRoute.app` | 无 Dock 项 |
| 项目私有 work 目录中的原样副本 | 有蓝色 L 图标 |
| 原路径注销后重新注册 | 仍无 Dock 项 |
| `/Applications/LumaRoute Local.app` | 有蓝色 L 图标 |

第 14 版当时采用 `/Applications/LumaRoute Local.app` 作为本机安装路径；当前路径见下方 Build 18 记录。旧包已移到私有 `work/dock-performance-2026-10-14/original-installed-path-backup.app`，仅作回退备份。没有重置 Dock、清空全局注册、修改安全校验或重新签名。已证明路径差异影响实际表现，尚不能断言底层是哪一种系统缓存或注册异常。

新路径启动后，真实后台服务已连接，内核已就绪，原节点选择已恢复。主程序与管理员服务快照的主程序 SHA256 相同，不需要新一轮管理员授权。用户最终确认：关闭主窗口后 Dock 图标消失；从菜单栏打开控制台后蓝色 L 图标恢复；最小化时 Dock 图标保留，点击恢复同一个窗口。

## 服务刷新与界面更新

- 第 14 版实际安装后台服务后，原 GUI 进程 PID 38074 不变，自动恢复 41 个代理对象和 9 个分组；该 PID 是历史验收进程，并非后续 Dock 排查中的当前进程。
- 高频流量、日志等更新改由 RuntimeData 跟踪；实际 AppStore 验证中，100 条日志加流量与历史更新造成的全局界面通知由 102 次降为 0，叶子视图仍能收到变化，导航仍触发更新。
- 使用 Release 构建。未测得屏幕帧率，滚动与页面切换的主观流畅度仍需用户日常使用确认。
- 菜单栏固定 60 点宽，速率右对齐，2178 个速率边界样本均能容纳；用户确认图标与速率的间距合适。

## 数据与网络保护

切换到新路径后，与验证前快照比较，database.json 和全部已记录订阅 YAML 的 SHA256 不变；系统代理输出不变。应用系统代理接管和 TUN 均关闭，原 127.0.0.1:7890 系统代理保留。

诊断原始结果存于本机私有 `work/dock-performance-2026-10-14/`，不包含在发布包中。不要把保留诊断包或备份包当作新的安装入口。

## Build 18：恢复 Dock 并保留 LumaRoute 名称

系统代理优化版本更新时，安装脚本重新使用了 `/Applications/LumaRoute.app`，此前已观察到的 Dock 缺失再次出现。当前运行应用的激活策略为 regular，主窗口和后台服务正常；这仍不能证明 Dock 图标实际存在。

保持 Build 18 的二进制、Info.plist、图标和签名不变，先移动到 `/Applications/LumaRoute Local.app`，用户确认 Dock 图标出现。用户随后明确要求应用只叫 **LumaRoute**，因此最终采用 `/Applications/LumaRoute/LumaRoute.app`。用户再次确认“图标正常，名称是 LumaRoute”。

- 当前安装路径：`/Applications/LumaRoute/LumaRoute.app`，包名及 CFBundleName 均为 LumaRoute。
- 应用启动后内核就绪、管理员后台服务运行正常，原美国住宅节点保留。
- 主程序、helper、Info.plist、图标哈希与移动前一致；主程序和 helper 与管理员服务快照匹配，无需重新授权。
- 已记录的 421 个原用户文件全部保持原哈希，系统代理输出与操作前一致；系统代理和 TUN 均关闭。
- 没有更改 Dock 全局配置、重签名或修改窗口显示逻辑；这是已通过用户实际验收的安装路径规避方式，底层系统原因仍未确定。

后续整体替换应沿用当前已验收路径，不重新创建 `/Applications/LumaRoute.app` 或添加 Local 名称。本次证据为 `work/dock-build18-2026-10-14/verification.json`，本地 Build 18 更新脚本已改用最终路径。
