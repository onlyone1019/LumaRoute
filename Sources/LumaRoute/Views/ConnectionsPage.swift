import SwiftUI
import Observation
import LumaRouteCore

@Observable @MainActor final class ConnectionsPageState {
    var search=""
    var selection:String?
    var network = "all"
    var policy = "all"
    var routingRule: CustomRule?
    var sortOrder = [KeyPathComparator(\LiveConnection.download,order:.reverse)]
}

struct ConnectionsPage:View {
    @EnvironmentObject var store:AppStore
    @State var state=ConnectionsPageState()
    var policies:[String] { Array(Set(store.connections.flatMap { $0.chains ?? [] })).sorted() }
    var items:[LiveConnection] {
        store.connections.filter { $0.matches(state.search) && (state.network == "all" || $0.metadata.network?.lowercased() == state.network) && (state.policy == "all" || $0.chains?.contains(state.policy) == true) }.sorted(using:state.sortOrder)
    }
    var selected:LiveConnection? { items.first { $0.id == state.selection } }
    var body:some View {
        @Bindable var state=state
        VStack(spacing:16) {
            PageHeader(title:"连接",subtitle:"\(items.count) 个连接") {
                StatusPill(text:store.coreReady ? "实时更新":"未连接内核",color:store.coreReady ? .green:.secondary)
                Button("刷新") { Task { await store.refreshConnectionsSnapshot() } }.disabled(store.busy || !store.coreReady)
                Button("关闭全部") { store.closeConnection(nil) }.disabled(store.connections.isEmpty)
            }
            HStack(spacing:12) {
                SearchField(placeholder:"搜索域名、进程、IP 或规则",text:$state.search)
                LumaPicker("协议",selection:$state.network,value:state.network == "all" ? "全部协议":state.network.uppercased()) { Text("全部协议").tag("all"); Text("TCP").tag("tcp"); Text("UDP").tag("udp") }.frame(width:155)
                LumaPicker("策略",selection:$state.policy,value:state.policy == "all" ? "全部策略":state.policy) { Text("全部策略").tag("all"); ForEach(policies,id:\.self) { Text($0).tag($0) } }.frame(width:190)
            }
            HStack(spacing:14) {
                table
                if let connection=selected { ConnectionDetails(connection:connection) { createRule(connection,application:$0) } }
            }
        }.sheet(item:$state.routingRule) { RoutingRuleSheet(rule:$0,profileID:store.database.activeProfileID) }
    }
    private var table:some View {
        @Bindable var state=state
        return ConnectionTableView(rows:items,selection:$state.selection,sortOrder:$state.sortOrder,
            targets:store.routingTargets,canCreateRule:!store.busy && store.activeProfile != nil,
            createRule:{ connection,application,target in createRule(connection,application:application,target:target) })
        .frame(maxWidth:.infinity,maxHeight:.infinity)
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
            state.routingRule = rule
        } catch { store.report(error) }
    }
}
