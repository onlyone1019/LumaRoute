# 第 15 版：批量测速崩溃修复

## 复现与范围

用户在第 14 版代理页点击“测试全部”后，GUI 发生 `EXC_BAD_ACCESS / SIGSEGV`，崩溃线程顶部为 `swift::TaskGroup::offer`。

`python3 script/check_latency_batch.py` 编译实际 AppStore、RuntimeData、HelperClient 并调用实际 MihomoAPI，连接只监听 127.0.0.1 的模拟内核。该验证不执行 bootstrap、不读取订阅凭据、不启动内核、不接管网络。

原实现退出码 139，系统崩溃记录同样位于 `TaskGroup::offer`。把局部入队函数改成显式传入任务组，或者内联任务入队，仍会崩溃，因此这些改动未保留。简单的 TaskGroup 和 URLSession 单独对照可以通过，尚不能把问题泛化为所有任务组或确定为某个系统版本缺陷。

## 最终变更

把测速任务的返回类型 `(String, Int?, String?)` 改成具名 `NodeTestResult: Sendable`，分别保存节点名、延迟和错误。保留原有并发上限、滚动入队、取消和代次隔离逻辑。没有切换 SDK、关闭优化或改为串行测速。

只保留返回类型变化后，原复现通过：

- 连续 10 轮，每轮 64 个节点，包含 7 个模拟失败；所有结果完成，延迟和错误统计正确。
- 取消后不再发布旧结果。
- 立即重测时，旧批次不覆盖新批次的进度、错误和运行状态。
- 空批次正确结束。
- CLI 原生回归 53 项通过。

这是在本机 Swift 6.4、macOS 27.0.1、Release 构建下验证的兼容性修复，未声称已确定编译器或运行时内部缺陷。测试脚本需要先通过项目构建入口生成 Release 的 LumaRouteCore/Yams 对象。

## 安装与真实验证

第 15 版安装到 `/Applications/LumaRoute.app`，旧包保存在本机私有 work 目录。后台服务已由用户同步，GUI 和服务快照的主程序 SHA256 一致。

真实代理页已观察到一轮完成 26/26；随后由自动化直接点击“测试全部”，再次从 3/26 跑到已完成 26/26。GUI PID 53096 保持不变，内核运行中，未出现新 GUI 崩溃记录。更新前后 database.json、已记录订阅 YAML 的 SHA256 及系统代理输出均一致，系统代理接管与 TUN 关闭。

原始本机证据位于 `work/latency-crash-2026-10-14/`，不会打包进应用。
