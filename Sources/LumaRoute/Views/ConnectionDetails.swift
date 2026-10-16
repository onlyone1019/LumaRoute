import SwiftUI
import LumaRouteCore

struct ConnectionDetails:View {
    @EnvironmentObject var store:AppStore
    let connection:LiveConnection
    let createRule:(Bool)->Void
    private var canRouteApp:Bool { connection.metadata.process?.isEmpty == false || connection.metadata.processPath?.isEmpty == false }
    private var route:String {
        let subscription = RoutingTools.subscription(for:connection,profiles:store.database.profiles,activeID:store.database.activeProfileID)
        return [connection.target,connection.rule ?? "未知规则",subscription,connection.chains?.first ?? "未知节点"].joined(separator:" → ")
    }
    var body:some View {
        Panel {
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    Text("连接详情").font(.system(size:17,weight:.semibold))
                    Text(route).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                    VStack(alignment:.leading,spacing:8) {
                        row("进程",connection.processName)
                        if let path=connection.metadata.processPath,!path.isEmpty { Text(path).font(.system(size:11)).foregroundStyle(.tertiary).textSelection(.enabled) }
                        if let source=connection.metadata.processSource { row("识别来源",source) }
                        row("目标",connection.target+":"+(connection.metadata.destinationPort ?? ""))
                        if let ip=connection.metadata.destinationIP { row("目标 IP",ip) }
                        row("来源",(connection.metadata.sourceIP ?? "")+":"+(connection.metadata.sourcePort ?? ""))
                        row("协议",connection.metadata.network ?? "未知")
                        row("接入",connection.metadata.type ?? "未知")
                        if let start=connection.start { row("开始时间",displayTime(start)) }
                    }.font(.system(size:13))
                    RowDivider()
                    VStack(alignment:.leading,spacing:6) {
                        Text("命中规则").font(.system(size:13,weight:.semibold))
                        Text((connection.rule ?? "")+","+(connection.rulePayload ?? "")).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Text("代理链").font(.system(size:13,weight:.semibold))
                        let chain = Array((connection.chains ?? []).reversed().enumerated())
                        ForEach(chain,id:\.offset) { item in
                            HStack(spacing:8) {
                                Circle().fill(item.offset == chain.count-1 ? LumaPalette.accent:Color.secondary.opacity(0.45)).frame(width:7,height:7)
                                Text(item.element).font(.system(size:13))
                            }
                        }
                    }
                    VStack(spacing:8) {
                        Button { createRule(false) } label:{ Text("为此域名创建分流").frame(maxWidth:.infinity) }.disabled(store.busy || store.activeProfile == nil)
                        Button { createRule(true) } label:{ Text("为此应用创建分流").frame(maxWidth:.infinity) }.disabled(store.busy || store.activeProfile == nil || !canRouteApp)
                        Button(role:.destructive) { store.closeConnection(connection.id) } label:{ Text("关闭此连接").foregroundStyle(.red).frame(maxWidth:.infinity) }
                    }.padding(.top,4)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }.frame(width:300)
    }
    private func row(_ title:String,_ value:String)->some View {
        HStack(alignment:.firstTextBaseline,spacing:10) {
            Text(title).foregroundStyle(.secondary).frame(width:64,alignment:.leading)
            Text(value).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func displayTime(_ value:String)->String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        guard let date = formatter.date(from:value) else { return value }
        return date.formatted(date:.omitted,time:.standard)
    }
}
