import SwiftUI
import LumaRouteCore

struct ConnectionsPage:View {
    @EnvironmentObject var store:AppStore
    @State private var search=""
    @State private var selection:String?
    @State private var network = "all"
    @State private var policy = "all"
    @State private var routingRule: CustomRule?
    @State private var sortOrder = [KeyPathComparator(\LiveConnection.download,order:.reverse)]
    var policies:[String] { Array(Set(store.connections.flatMap { $0.chains ?? [] })).sorted() }
    var items:[LiveConnection] {
        store.connections.filter { $0.matches(search) && (network == "all" || $0.metadata.network?.lowercased() == network) && (policy == "all" || $0.chains?.contains(policy) == true) }.sorted(using:sortOrder)
    }
    var selected:LiveConnection? { items.first { $0.id == selection } }
    var body:some View {
        VStack(spacing:16) {
            PageHeader(title:"连接",subtitle:"\(items.count) 个连接") {
                StatusPill(text:store.coreReady ? "实时更新":"未连接内核",color:store.coreReady ? .green:.secondary)
                Button("刷新") { Task { await store.refreshConnectionsSnapshot() } }.disabled(store.busy || !store.coreReady)
                Button("关闭全部") { store.closeConnection(nil) }.disabled(store.connections.isEmpty)
            }
            HStack(spacing:12) {
                SearchField(placeholder:"搜索域名、进程、IP 或规则",text:$search)
                LumaPicker("协议",selection:$network,value:network == "all" ? "全部协议":network.uppercased()) { Text("全部协议").tag("all"); Text("TCP").tag("tcp"); Text("UDP").tag("udp") }.frame(width:155)
                LumaPicker("策略",selection:$policy,value:policy == "all" ? "全部策略":policy) { Text("全部策略").tag("all"); ForEach(policies,id:\.self) { Text($0).tag($0) } }.frame(width:190)
            }
            HStack(spacing:14) {
                table
                if let connection=selected { ConnectionDetails(connection:connection) { createRule(connection,application:$0) } }
            }
        }.sheet(item:$routingRule) { RoutingRuleSheet(rule:$0,profileID:store.database.activeProfileID) }
    }
    private var table:some View {
        Table(items,selection:$selection,sortOrder:$sortOrder) {
            TableColumn("进程",value:\.processName) { Text($0.processName) }.width(min:70,ideal:90)
            TableColumn("目标",value:\.target) { Text($0.target) }.width(min:110,ideal:150)
            TableColumn("策略",value:\.policyName) { Text($0.policyName) }.width(min:80,ideal:110)
            TableColumn("下载",value:\.download) { Text(Format.bytes($0.download)).monospacedDigit() }.width(75)
            TableColumn("上传",value:\.upload) { Text(Format.bytes($0.upload)).monospacedDigit() }.width(70)
        }
        .scrollContentBackground(.hidden).alternatingRowBackgrounds(.disabled).scrollIndicators(.hidden,axes:.horizontal)
        .contextMenu(forSelectionType:String.self) { ids in
            if ids.count == 1,let id = ids.first,let connection = items.first(where:{$0.id == id}) {
                Menu("此域名以后走") {
                    ForEach(store.routingTargets,id:\.name) { target in Button(target.label) { createRule(connection,application:false,target:target.name) } }
                }.disabled(store.busy || store.activeProfile == nil)
                Menu("此应用以后走") {
                    ForEach(store.routingTargets,id:\.name) { target in Button(target.label) { createRule(connection,application:true,target:target.name) } }
                }.disabled(store.busy || store.activeProfile == nil || (connection.metadata.process?.isEmpty != false && connection.metadata.processPath?.isEmpty != false))
            }
        }
        .overlay {
            if items.isEmpty {
                EmptyMessage(icon:"network",title:store.connections.isEmpty ? "暂无连接":"没有匹配的连接",detail:store.connections.isEmpty ? "应用通过 LumaRoute 联网后，连接会显示在这里。":"试试其他关键词、协议或策略。")
            }
        }
        .background(LumaPalette.card,in:RoundedRectangle(cornerRadius:LumaPalette.cardRadius,style:.continuous))
        .clipShape(RoundedRectangle(cornerRadius:LumaPalette.cardRadius,style:.continuous))
    }
    private func createRule(_ connection: LiveConnection,application: Bool,target: String? = nil) {
        do {
            var rule = try application ? RoutingTools.applicationRule(for:connection):RoutingTools.domainRule(for:connection)
            rule.target = target ?? (store.routingTargets.contains(where:{$0.name == connection.policyName}) ? connection.policyName:"DIRECT")
            routingRule = rule
        } catch { store.report(error) }
    }
}
