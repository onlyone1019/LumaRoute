import SwiftUI
import LumaRouteCore

struct ConnectionsPage:View {
    @EnvironmentObject var store:AppStore
    @State private var search=""
    @State private var selection:String?
    @State private var network = "all"
    @State private var policy = "all"
    @State private var sortOrder = [KeyPathComparator(\LiveConnection.download,order:.reverse)]
    var policies:[String] { Array(Set(store.connections.flatMap { $0.chains ?? [] })).sorted() }
    var items:[LiveConnection] {
        store.connections.filter { $0.matches(search) && (network == "all" || $0.metadata.network?.lowercased() == network) && (policy == "all" || $0.chains?.contains(policy) == true) }.sorted(using:sortOrder)
    }
    var selected:LiveConnection? { items.first { $0.id == selection } }
    var body:some View {
        VStack(spacing:18) {
            PageHeader(title:"连接") { Label(store.coreReady ? "实时更新":"未连接内核",systemImage:"circle.fill").font(.caption).foregroundStyle(store.coreReady ? .green:.secondary); Button("关闭全部") { store.closeConnection(nil) }.disabled(store.connections.isEmpty) }
            HStack {
                SearchField(placeholder:"搜索域名、进程、IP 或规则",text:$search)
                Picker("协议",selection:$network) { Text("全部协议").tag("all"); Text("TCP").tag("tcp"); Text("UDP").tag("udp") }.frame(width:155)
                Picker("策略",selection:$policy) { Text("全部策略").tag("all"); ForEach(policies,id:\.self) { Text($0).tag($0) } }.frame(width:190)
            }
            HStack(spacing:14) {
                Table(items,selection:$selection,sortOrder:$sortOrder) {
                    TableColumn("进程",value:\.processName) { Text($0.processName) }.width(min:70,ideal:90)
                    TableColumn("目标",value:\.target) { Text($0.target) }.width(min:110,ideal:150)
                    TableColumn("策略",value:\.policyName) { Text($0.policyName) }.width(min:80,ideal:110)
                    TableColumn("下载",value:\.download) { Text(Format.bytes($0.download)) }.width(75)
                    TableColumn("上传",value:\.upload) { Text(Format.bytes($0.upload)) }.width(70)
                }
                .overlay {
                    if items.isEmpty {
                        EmptyMessage(icon:"network",title:store.connections.isEmpty ? "暂无连接":"没有匹配的连接",detail:store.connections.isEmpty ? "应用通过 LumaRoute 联网后，连接会显示在这里。":"试试其他关键词、协议或策略。")
                            .background(.background)
                    }
                }
                if let connection=selected {
                    Panel {
                        VStack(alignment:.leading,spacing:15) {
                            Text("连接详情").font(.title3.bold())
                            LabeledContent("进程",value:connection.processName)
                            if let path=connection.metadata.processPath,!path.isEmpty { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if let source=connection.metadata.processSource { LabeledContent("识别来源",value:source).font(.caption) }
                            LabeledContent("目标",value:connection.target+":"+(connection.metadata.destinationPort ?? ""))
                            if let ip=connection.metadata.destinationIP { LabeledContent("目标 IP",value:ip) }
                            LabeledContent("来源",value:(connection.metadata.sourceIP ?? "")+":"+(connection.metadata.sourcePort ?? ""))
                            LabeledContent("协议",value:connection.metadata.network ?? "未知")
                            LabeledContent("接入",value:connection.metadata.type ?? "未知")
                            if let start=connection.start { LabeledContent("开始时间",value:displayTime(start)).font(.caption) }
                            Divider()
                            Text("命中规则").font(.headline)
                            Text((connection.rule ?? "") + "," + (connection.rulePayload ?? "")).font(.caption).textSelection(.enabled)
                            Divider(); Text("代理链").font(.headline)
                            ForEach(Array((connection.chains ?? []).reversed().enumerated()),id:\.offset) { item in Label(item.element,systemImage:"circle").font(.subheadline) }
                            Spacer()
                            Button("关闭此连接") { store.closeConnection(connection.id) }.frame(maxWidth:.infinity)
                        }.frame(maxHeight:.infinity,alignment:.topLeading)
                    }.frame(width:300)
                }
            }
            HStack { Text("\(items.count) 个连接").font(.caption).foregroundStyle(.secondary); Spacer() }
        }
    }
    private func displayTime(_ value:String)->String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        guard let date = formatter.date(from:value) else { return value }
        return date.formatted(date:.omitted,time:.standard)
    }
}

