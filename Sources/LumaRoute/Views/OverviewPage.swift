import SwiftUI
import LumaRouteCore

struct OverviewPage:View {
    @EnvironmentObject var store:AppStore
    @State private var showingDiagnostics = false
    private var leafNode:ProxyNode? {
        var next = store.activeNode
        var visited:Set<String> = []
        while visited.insert(next).inserted,let node = store.proxies[next] {
            if !node.isGroup { return node }
            guard let current = node.now else { return nil }; next = current
        }
        return nil
    }
    var body:some View {
        ScrollView {
            VStack(spacing:14) {
                PageHeader(title:"概览") { }
                hero
                HStack(spacing:14) { nodeTile; serviceTile }
                traffic
                maintenance
            }.frame(maxWidth:.infinity)
        }.sheet(isPresented:$showingDiagnostics) { NetworkDiagnosticsSheet() }
    }
    private var hero:some View {
        Panel(padding:20) {
            VStack(alignment:.leading,spacing:18) {
                HStack(spacing:16) {
                    Image(systemName:store.connected ? "checkmark":"network")
                        .font(.system(size:24,weight:.semibold)).foregroundStyle(store.connected ? Color.white:LumaPalette.accent)
                        .frame(width:56,height:56).background(store.connected ? Color.green:LumaPalette.accent.opacity(0.14),in:Circle())
                    VStack(alignment:.leading,spacing:5) {
                        Text(store.connected ? "连接正常":store.coreReady ? "内核已就绪":"内核未就绪").font(.system(size:20,weight:.semibold))
                        Text("当前配置：\(store.activeProfile?.name ?? "尚未导入订阅")").font(.system(size:13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength:12)
                    Button { store.toggleConnection() } label: {
                        Label(store.connected ? "暂停连接":"连接",systemImage:store.connected ? "pause.fill":"play.fill")
                    }.buttonStyle(.borderedProminent).disabled(store.busy || !store.coreReady)
                }
                HStack(spacing:20) {
                    Text("代理模式").foregroundStyle(.secondary)
                    Picker("代理模式",selection:Binding(get:{store.database.settings.mode},set:{store.setMode($0)})) {
                        ForEach(RouteMode.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    Spacer(minLength:0)
                    Toggle("系统代理",isOn:Binding(get:{store.database.settings.systemProxy},set:{store.setNetwork(systemProxy:$0)})).toggleStyle(.switch)
                    Toggle("TUN 模式",isOn:Binding(get:{store.database.settings.tun},set:{store.setNetwork(tun:$0)})).toggleStyle(.switch)
                }.font(.system(size:13)).padding(.horizontal,16).padding(.vertical,12)
                    .background(LumaPalette.tile,in:RoundedRectangle(cornerRadius:12,style:.continuous)).disabled(store.busy)
            }
        }
    }
    private var nodeTile:some View {
        Panel {
            HStack(spacing:14) {
                IconBadge(icon:"server.rack")
                VStack(alignment:.leading,spacing:5) {
                    Text("当前节点").font(.system(size:12)).foregroundStyle(.secondary)
                    Text(leafNode?.name ?? store.activeNode).font(.system(size:16,weight:.semibold)).lineLimit(1)
                    HStack(spacing:8) {
                        if let delay = leafNode?.delay { LatencyChip(delay:delay) }
                        Text(store.database.settings.mode.label+"模式").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength:0)
            }.frame(minHeight:64)
        }
    }
    private var serviceTile:some View {
        Panel {
            HStack(spacing:14) {
                IconBadge(icon:"gearshape.fill",tint:store.serviceRunning ? .green:.secondary)
                VStack(alignment:.leading,spacing:5) {
                    Text("后台服务").font(.system(size:12)).foregroundStyle(.secondary)
                    HStack(spacing:7) { StatusDot(active:store.serviceRunning); Text(store.serviceRunning ? "运行中":store.serviceLabel).font(.system(size:16,weight:.semibold)).lineLimit(1) }
                }
                Spacer(minLength:8)
                Button("查看设置") { store.settingsTab = "网络"; store.page = .settings }
            }.frame(minHeight:64)
        }
    }
    private var traffic:some View {
        Panel(padding:20) {
            HStack(alignment:.top,spacing:28) {
                VStack(alignment:.leading,spacing:20) {
                    Text("实时流量").font(.system(size:15,weight:.semibold))
                    rateBlock("下载",rate:store.traffic.down,total:store.traffic.downTotal ?? 0,color:LumaPalette.accent)
                    rateBlock("上传",rate:store.traffic.up,total:store.traffic.upTotal ?? 0,color:LumaPalette.upload)
                }.frame(width:190,alignment:.leading)
                TrafficGraph(samples:store.trafficHistory).frame(height:208)
            }
        }
    }
    private var maintenance:some View {
        Panel {
            VStack(spacing:16) {
                HStack(spacing:14) {
                    IconBadge(icon:"tray.full",size:36)
                    VStack(alignment:.leading,spacing:2) {
                        Text(store.activeProfile?.name ?? "添加你的第一个订阅").font(.system(size:14,weight:.medium)).lineLimit(1)
                        if let updated = store.activeProfile?.lastUpdated { Text("更新于 "+updated.formatted(date:.omitted,time:.shortened)).font(.system(size:12)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(store.activeProfile == nil ? "添加订阅":"更新订阅") {
                        if store.activeProfile != nil { store.perform { try await store.updateActiveSubscriptions() } }
                        else { store.page = .subscriptions; store.addingSubscription = true }
                    }.disabled(store.busy)
                }
                HStack(spacing:14) {
                    IconBadge(icon:"checkmark.shield",size:36,tint:store.coreReady ? .green:.secondary)
                    VStack(alignment:.leading,spacing:2) {
                        Text("网络检查").font(.system(size:14,weight:.medium))
                        Text(store.coreReady ? "内核可访问":"内核尚未就绪").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新检查") { Task { await store.recheck() } }
                    Button("网络诊断") { showingDiagnostics = true }.disabled(store.busy)
                }
            }
        }
    }
    private func rateBlock(_ title:String,rate:Int64,total:Int64,color:Color)->some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(spacing:6) { Circle().fill(color).frame(width:8,height:8); Text(title).font(.system(size:12)).foregroundStyle(.secondary) }
            RateText(text:Format.rate(rate))
            Text("本次 "+Format.bytes(total)).font(.system(size:12)).foregroundStyle(.secondary)
        }
    }
}

/// Large number with a small unit, split at the first space of the formatted rate.
private struct RateText:View {
    var text:String
    var body:some View {
        let split = text.firstIndex(where:{ $0.isWhitespace })
        HStack(alignment:.firstTextBaseline,spacing:4) {
            Text(split.map { String(text[..<$0]) } ?? text).font(.system(size:28,weight:.semibold)).monospacedDigit()
            Text(split.map { String(text[text.index(after:$0)...]) } ?? "").font(.system(size:13,weight:.medium)).foregroundStyle(.secondary)
        }
    }
}
