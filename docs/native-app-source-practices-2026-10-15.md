# 原生 macOS 应用响应实践：官方源码核查

核查日期：2026-10-15。范围：只读研究其他应用源码；未修改 LumaRoute 应用代码，未访问用户业务数据、凭据或运行中的代理配置。

## 样本与证据边界

| 应用 | 本次固定版本 | 原生界面证据与范围 |
| --- | --- | --- |
| Stats，exelban 官方仓库 | `c9e7ebe3390a84e3075946ffe39dda709c4747b1`，提交时间 2026-10-14 | `NSStackView`、`NSWindow`、`NSViewController` 实现的 AppKit 弹出面板；本文研究当前源码，不代表全部历史发行版。[源码](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Kit/module/popup.swift#L44-L85) |
| sing-box for Apple，SagerNet 官方仓库 | `56681841de346fb2185dc6eceba415f6b41bb2b2`，提交时间 2026-10-11 | macOS 入口使用 AppKit + SwiftUI；共享 ApplicationLibrary 包含出站组、日志和连接界面。README 自称实验性客户端，不能因此视作经过性能认证的金标准。[macOS 主视图](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/MacLibrary/MainView.swift#L1-L40)、[README](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/README.md#L1-L7) |

尝试读取原作者仓库 `https://github.com/yichengchen/clashX.git`，本次返回 Repository not found。因此没有采用重新上传的 fork，不能据本次材料声称 ClashX 内部具体使用何种菜单缓存机制。没有研究闭源 Surge 的内部实现，没有测量这些第三方应用的点击响应时间，也没有把 Electron/Tauri 项目当作原生 AppKit/SwiftUI 样本。

## Stats：保留便宜且常用的面板，隐藏时减少工作

### 1. 面板对象常驻，打开路径主要是定位和显示

事实：`Module` 将 `popup` 与 `popupView` 存为属性，在初始化中创建一次 `PopupWindow`。点击切换函数取得已有窗口，调整位置并调用 `setIsVisible(true/false)`，该函数没有重新构造整个面板。[对象持有和初始化](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Kit/module/module.swift#L97-L105)、[窗口创建](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Kit/module/module.swift#L162-L172)、[打开路径](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Kit/module/module.swift#L313-L357)。

推论：对频繁打开且结构相对稳定的状态面板，可以把结构构造移出每次点击的关键路径。这个样本使用的是 AppKit 自定义窗口，不是 NSMenu；它也不是“所有界面必须懒创建”的例子，恰好有一部分是启动时预建。不能直接据此要求所有 SwiftUI 页面同时挂载、常驻重型编辑器或隐藏页面继续订阅高频数据。

### 2. 隐藏时保留最新值，重新打开直接重放

事实：`PopupCache.apply` 每次保留最新值，但仅在可见或首次初始化时调用渲染；`replay` 从缓存渲染。CPU 面板在 `appear()` 中重放负载、温度、频率等缓存。[缓存策略](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Kit/module/popup.swift#L14-L30)、[可见性传入](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Kit/module/popup.swift#L69-L77)、[CPU 重放](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Modules/CPU/popup.swift#L171-L178)。

推论：最后一份可信快照可以服务首次绘制，后续读数再更新；打开 UI 不必等待下一次采样完成。缓存的有效性、错误状态与过期时间仍需产品自己定义。代码没有比较新旧值是否相同，因此不能将这一段称作“所有数据相等去重”。

### 3. 按消费者可见性暂停专用读数，保留必要的基础采样

事实：`readerHasVisibleConsumer` 同时考虑模块是否启用、弹出窗口和设置是否可见；`updateReaderVisibility` 对 popup、preview 或 sleep 类 reader 在不可见时执行 `pause`。普通基础 reader 不在该分支中无条件暂停。[可见消费者计算与启停](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Kit/module/module.swift#L261-L309)。

推论：窗口隐藏后，应取消只服务该页面的昂贵读取与渲染；状态栏指标、网络连接、内核状态等必要工作按各自需求继续。不能概括成“后台一律停止采样”。

### 4. 读数、图表状态与 UI 操作分工

事实：Reader 的首轮读取投到后台队列，周期读取由 Repeater 调用；图表在自己的并发队列保存状态，只在主线程且窗口可见时设置 `needsDisplay`。[Reader 启动](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Kit/module/reader.swift#L133-L159)、[周期调度](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Kit/module/reader.swift#L209-L218)、[图表状态与显示](https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Kit/plugins/Charts.swift#L157-L203)。

限制：后台并不等于无成本；同步队列访问、状态拷贝、主线程的实际渲染仍有成本。本次没有运行 Stats 的 Instruments，不能断言其所有路径都没有主线程阻塞。

## sing-box Apple：减少无效发布，让点击先获得局部反馈

### 5. 同一批流量更新只发布一份一致快照

事实：状态、上行曲线、下行曲线归入一个 `trafficSnapshot`；收到状态时先修改本地副本，再对 `@Published` 属性赋值一次。[快照定义](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/Library/Network/CommandClient.swift#L65-L114)、[单次提交](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/Library/Network/CommandClient.swift#L490-L503)。

推论：一份业务更新包含多个字段时，先算好再提交，能减少中间状态传播。这不是按字段访问自动隔离；它仍是 ObservableObject，不能据此认为订阅者只重绘实际读取过的字段。

### 6. 新旧出站组相同，阻止无效通知继续传播

事实：CommandClient 转换出站组数据后先与 `lastGroups` 比较，相同则直接返回；页面模型 `setGroups` 合并 pending 状态后再次比较，仅变化时赋值给 `groups`。[接收层去重](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/Library/Network/CommandClient.swift#L506-L523)、[页面模型去重](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/ApplicationLibrary/Views/Groups/GroupListViewModel.swift#L38-L61)。

推论：轮询成功不等于需要发 UI 通知。相同值提前返回，比通知后再让所有视图重新计算更靠近源头。完整数组比较也有成本，需要根据数据量衡量，而非无条件对巨大模型做深比较。

### 7. 节点点击先更新本地状态，再发送命令；旧回包不能立即盖回新选择

事实：`selectOutbound` 立即改本地组的 selected，并记录 `pendingSelections`；随后 Task 调用 `nonisolated async` 的命令函数。收到组数据时，如果核心尚未确认该选择，仍保留 pending 选择；核心确认匹配时删除 pending 项。展开操作采用类似逻辑。[选择和确认](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/ApplicationLibrary/Views/Groups/GroupListViewModel.swift#L38-L81)、[展开反馈](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/ApplicationLibrary/Views/Groups/GroupListViewModel.swift#L84-L103)。

限制：当前 `catch` 显示 alert，没有在该路径撤销本地选择或清除 pending 项；全文件检索到的 pending 清除仅发生在收到匹配确认时。因此这是“即时局部反馈”的可参考案例，不应原样当作完整的失败回滚方案。LumaRoute 若采用该模式，应定义命令失败、超时、取消以及连续选择乱序的处理，区分“选择已收到”与“核心已生效”。

### 8. 高频日志分批提交，首屏不必等待批处理窗口

事实：日志批次窗口为 100 ms；`flushPendingLogs` 先本地组装受大小限制的日志缓冲，再发布一次。首次日志批次立即刷新，后续批次才等待窗口。[窗口定义](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/Library/Network/CommandClient.swift#L142-L145)、[缓冲一次提交](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/Library/Network/CommandClient.swift#L259-L273)、[首次与后续批次](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/Library/Network/CommandClient.swift#L471-L485)。

推论：批处理服务于减少高频数据刷新，不应将同样延迟直接套到鼠标点击、导航、开关的第一帧反馈上。

### 9. 有稳定页面模型和惰性列表，但不能据此声称跨页面永久保活

事实：macOS 主视图用 `@StateObject MainViewModel` 保存选择；出站组视图有独立 `@StateObject GroupListViewModel`，列表使用 `LazyVStack` 和稳定的 tag 标识。主视图 detail 由 `selection.contentView` 提供；离开设置页时主动清空设置导航路径。[主模型和导航](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/MacLibrary/MainView.swift#L7-L18)、[detail](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/MacLibrary/MainView.swift#L60-L72)、[设置路径清理](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/MacLibrary/MainView.swift#L130-L143)、[组视图模型和列表](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/ApplicationLibrary/Views/Groups/GroupListView.swift#L4-L30)。

限制：`@StateObject` 的持有范围取决于视图身份与生命周期，本文没有验证返回页面时全部内部状态是否保留。不能从这个声明推导所有页面切走之后永不重建。

## 同样需要看到的反例

sing-box Apple 并未把所有转换与排序放到后台：连接事件在 `DispatchQueue.main.async` 内更新 store、排序过滤并发布；`ConnectionDataModel` 也是 MainActor 上的模型，收到连接后进行转换和搜索过滤。[事件处理](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/Library/Network/CommandClient.swift#L553-L566)、[连接模型](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/ApplicationLibrary/Views/Connections/ConnectionListViewModel.swift#L6-L14)、[转换与过滤](https://github.com/SagerNet/sing-box-for-apple/blob/56681841de346fb2185dc6eceba415f6b41bb2b2/ApplicationLibrary/Views/Connections/ConnectionListViewModel.swift#L60-L109)。没有性能测量，既不能断言其会卡顿，也不能把它描述成“成熟原生应用都不会在主线程处理列表”。

## 可以带回 LumaRoute 的候选原则

以下是根据上述源码归纳的工程建议，不是第三方跑分结论，也不是 LumaRoute 已完成的优化：

1. 将“收到点击并显示反馈”的路径与“获取最新业务数据、解析、校验并提交”的路径分开；重要状态的生效与失败必须真实可见。
2. 菜单和常用弹出面板先明确结构变化频率；可复用结构、缓存快照、局部更新状态，避免打开一次构造一次。不能只看到某一项目使用缓存就强制整应用全常驻。
3. 在数据入口、快照提交和页面模型层减少相同值发布，并避免一批读数多次发布互不一致的中间状态。
4. 隐藏页面停掉它专属的昂贵订阅和渲染，保留最新可信快照供返回时展示；内核与必要后台任务独立维持。
5. 列表有稳定身份、页面有清晰状态归属；大列表按需构造。是否保留页面对象或只保留模型，需要测量构造成本与常驻成本。
6. 最后用 LumaRoute 自身的输入到首帧、主线程长任务、body 更新原因、冷/热打开和高频数据下的 p95 证据决定顺序。源码模式只能给候选方向，不能证明应用体验优劣。
