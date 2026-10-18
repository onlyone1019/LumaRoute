# 生效规则滚动后内存上涨与切页卡顿

## 复现与原因

触发顺序是打开“规则 → 生效规则”、逐屏滚到底部，再切到概览。只打开列表而不遍历，不能覆盖这个问题。

在 macOS 27.0.1、Apple Silicon、SDK 27.0 Release 隔离宿主中，用生产 `RulesPage`、`RootView` 和页面缓存实现加载合成规则。宿主不执行 `AppStore.bootstrap()`，不访问正式配置或启动内核/Helper。测试源副本只将规则页初始分类预选为生效规则。

6,000 条规则的旧实现滚动时 CPU 接近占满一个核心，物理内存达到约 2.4 GiB，并在 90 秒内未完成。采样热点集中在 `NSTableRowData._automaticRowHeightsUpdateVisibleRowViews`、行视图创建和 SwiftUI 行内容。退出这个隔离进程后，将样本缩小到 2,000 条，得到以下可完成的复现。

| 阶段 | 旧实现物理内存 MiB | 修复后物理内存 MiB |
| --- | ---: | ---: |
| 概览基线 | 39.20 | 39.03 |
| 打开生效规则 | 51.84 | 55.02 |
| 逐屏滚到底 | 863.39 | 54.59 |
| 切回概览 | 896.03 | 55.33 |
| 打开设置 | 902.28 | 61.39 |

滚动后的概览切页测量从 21,849.5 ms 降至 128.3 ms。两边均包含人为固定的 120 ms 等待，以及后续布局和显示；这不是用户输入到屏幕呈现的端到端延迟，也不是长期统计结果。

单变量探针只关闭旧表格的自动行高，滚动后物理内存降至约 62.84 MiB，概览切页约 128.0 ms。这支持自动测高路径是主因，页面缓存则使已膨胀的表格在切页后仍被保留。

## 修复

`LiveRulesTableView` 沿用连接页的窄范围 AppKit 桥接，自行创建固定 24 点行高的表格，复用行视图和文本单元格，数据相同时跳过重载。仅复用文本单元格而不复用行视图时，同一测试仍有约 96 MiB 增量；补齐行视图复用后降到约 22 MiB。

保留类型/匹配内容/目标策略三列、原列宽、原搜索条件、卡片背景与圆角。规则页面仍由原宿主缓存，自定义规则草稿和分类状态不因这次修复而重建。未改变规则获取、业务配置、代理、TUN 或 Helper 行为。

## 验证

```bash
./script/build_and_run.sh --build-only
python3 script/check_live_rules.py --output work/live-rules-2026-10-18/regression-after
python3 script/check_live_rules.py --rows 6000 --output work/live-rules-2026-10-18/regression-6000
codesign --verify --deep --strict dist/LumaRoute.app
```

2,000 条规则三轮回归通过 57 项检查，覆盖逐屏遍历、滚动后切页、后台无关状态更新、缓存页面返回、缩放、深浅色切换、规则内容替换、清空和重新填充；没有 AppKit 表格重入警告。截图测试包含额外图片缓冲，其内存数字不用于上面的最小复现对比。

6,000 条规则三轮完整遍历也通过 57 项检查，物理内存最大增量 64.16 MiB，滚动后各页切换均低于 500 ms，没有重入警告。

另用 CUA 操作隔离宿主，验证搜索最后一条规则、清除搜索、75 次逐屏滚动到底、随后切换概览，确认布局和响应。完整 arm64 Release 构建、SDK/最低系统版本检查和应用深度签名验证通过。正式已安装应用和后台服务未被替换；尚未进行 Intel 真机或其他 macOS 版本验收。

原始测量与采样位于 Git 忽略的 `work/live-rules-2026-10-18/`，包括 `minimized-before.json`、`fixed-height-probe.json`、`reused-after.json`、`scroll-before.sample.txt` 和回归报告。


## 连接页行视图复用补齐

后续逐页排查发现：连接页已经固定行高并复用文本单元格，但 `rowViewForRow` 每次仍创建新的 `NSTableRowView`。2,000 条连接重复滚动时，行视图占用逐轮增加。只为原 `RowView` 设置复用标识，并优先从表格的复用队列取回行；保留原绘制类、分隔线、行高、字体、列宽、排序、选择和分流回调。

在原连接页 GUI 回归中先补充三轮完整遍历和物理内存检查，再用修复前源码副本运行。旧实现恰好失败于两项内存断言，其余功能检查通过。相同 fixture、相同完整页面宿主下的结果为：

| 轮次 | 修复前物理内存 MiB | 修复后物理内存 MiB |
| --- | ---: | ---: |
| 第一轮滚到底 | 153.09 | 90.83 |
| 第二轮滚到底 | 212.95 | 101.13 |
| 第三轮滚到底 | 262.66 | 99.84 |

独立页面宿主也通过，三轮约 79.59、77.84、79.47 MiB。两个模式共通过 549 项检查、480 次整批连接刷新，自动行高违规和表格重入警告均为零。覆盖滚动、页间往返、搜索、协议/策略筛选、升降序排序、原生行选择、右键分流目标、窗口缩放、主题切换和页面回收重建。

初始列表、选中连接及空列表三张完整页面 PNG 与修复前 SHA-256 完全相同；原生表格的行高、间距、列宽、表头高度等样式快照也完全相同。对比文件位于 `work/connection-row-reuse-2026-10-18/ui-comparison.json`。

```bash
python3 script/check_connection_table.py --products .build/arm64-apple-macosx/release --output work/connection-row-reuse-2026-10-18/after-check
./script/build_and_run.sh --build-only
codesign --verify --deep --strict dist/LumaRoute.app
```

本轮仍只构建和测试本地源码，正式安装的应用、后台服务和网络设置没有被替换或修改。测试结果限于当前 Apple Silicon/macOS 环境和上述固定负载。
