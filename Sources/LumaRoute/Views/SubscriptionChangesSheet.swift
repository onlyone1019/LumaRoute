import SwiftUI
import LumaRouteCore

struct SubscriptionChangesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("订阅更新变化").font(.title2.bold())
            if let change = profile.lastChange {
                Text(profile.name+" · "+change.date.formatted(date:.abbreviated,time:.shortened)).foregroundStyle(.secondary)
                Text(change.summary).font(.headline)
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        if !change.selectedNodesRemoved.isEmpty { Text("原选中的节点已被移除："+change.selectedNodesRemoved.joined(separator:"、")+"。请检查当前出口，内核可能已选择其他可用节点。").foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
                        names("新增节点",change.addedNodes)
                        names("移除节点",change.removedNodes)
                        names("参数变化的节点",change.changedNodes)
                        names("新增策略组",change.addedGroups)
                        names("移除策略组",change.removedGroups)
                        names("变化的代理提供者",change.changedProviders)
                        if change.containsProviders { Text("这里只比较订阅配置中直接声明的节点和提供者定义，不包含远程 provider 内部的节点更新。").font(.caption).foregroundStyle(.secondary) }
                        if change.uriNamesOnly { Text("URI 订阅按节点名称比较；未命名节点按行序号区分，重复名称可能合并显示。").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(minHeight:200,maxHeight:380)
            }
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width:620)
    }
    @ViewBuilder private func names(_ title: String,_ values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment:.leading,spacing:5) {
                Text(title+"（\(values.count)）").font(.headline)
                ForEach(Array(values.prefix(250).enumerated()),id:\.offset) { _,name in Text(name).font(.callout).textSelection(.enabled) }
                if values.count > 250 { Text("另有 \(values.count-250) 项").foregroundStyle(.secondary) }
            }
        }
    }
}
