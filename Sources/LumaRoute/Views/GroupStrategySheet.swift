import SwiftUI
import LumaRouteCore

struct GroupStrategySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let group: ProxyNode
    @State private var draft: GroupStrategy
    @State private var failure: String?
    init(group: ProxyNode, draft: GroupStrategy) { self.group = group; _draft = State(initialValue:draft) }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            VStack(alignment:.leading,spacing:4) {
                Text("策略设置").font(.title2.bold())
                Text(group.name).font(.system(size:14)).foregroundStyle(.secondary)
            }
            SettingsGroup {
                NativeRow(title:"选择方式") { LumaPicker("选择方式",selection:$draft.mode,value:draft.mode.label) { ForEach(GroupStrategyMode.allCases) { Text($0.label).tag($0) } }.frame(width:220) }
                if draft.mode != .subscription {
                    RowDivider()
                    NativeRow(title:"候选范围") { LumaPicker("候选范围",selection:$draft.candidateFilter,value:draft.candidateFilter.isEmpty ? "全部代理节点":"仅日本节点") { Text("全部代理节点").tag(""); Text("仅日本节点").tag(GroupStrategy.japanFilter) }.frame(width:220) }
                    RowDivider()
                    NativeRow(title:"测试间隔") { Stepper("\(draft.interval) 秒",value:$draft.interval,in:10...3600,step:10).fixedSize().accessibilityLabel("测试间隔").accessibilityValue("\(draft.interval) 秒") }
                    if draft.mode == .lowestLatency {
                        RowDivider()
                        NativeRow(title:"切换容差") { Stepper("\(draft.tolerance) ms",value:$draft.tolerance,in:0...1000,step:10).fixedSize().accessibilityLabel("切换容差").accessibilityValue("\(draft.tolerance) 毫秒") }
                    }
                }
            }
            if draft.mode != .subscription {
                VStack(alignment:.leading,spacing:4) {
                    Text(draft.mode == .lowestLatency ? "定时测试候选节点。新节点的延迟改善超过容差时才切换，避免频繁跳动。" : "按原候选顺序优先使用第一个可用节点；当前节点不可用时切换到下一个。")
                    Text("测试目标：\(store.database.settings.testURL)")
                }.font(.system(size:12)).foregroundStyle(.secondary)
            }
            Text("仅对当前订阅的这个组生效。组名与其他组的引用关系保留；自动候选排除直连和策略组。选回“保持订阅策略”可恢复原分组。").font(.system(size:12)).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.system(size:12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用策略") {
                    let strategy = draft
                    store.perform {
                        do { try await store.saveStrategy(strategy); dismiss() }
                        catch { failure = Redactor.clean(error.localizedDescription) }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:550).disabled(store.busy)
    }
}
