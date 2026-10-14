import SwiftUI
import LumaRouteCore

struct OverviewPage:View {
    @EnvironmentObject var store:AppStore
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
                PageHeader(title:"概览") {
                    Button { store.toggleConnection() } label: {
                        Label(store.connected ? "暂停连接":"连接",systemImage:store.connected ? "pause.fill":"play.fill")
                    }.buttonStyle(LumaPrimaryButtonStyle()).disabled(store.busy || !store.coreReady)
                }
                Panel {
                    VStack(alignment:.leading,spacing:14) {
                        HStack(spacing:16) {
                            Image(systemName:store.connected ? "checkmark":"network")
                                .font(.system(size:25,weight:.medium)).foregroundStyle(store.connected ? .white:LumaPalette.accent)
                                .frame(width:50,height:50)
                                .background(store.connected ? Color.green:LumaPalette.accent.opacity(0.09),in:Circle())
                            VStack(alignment:.leading,spacing:6) {
                                Text(store.connected ? "连接正常":store.coreReady ? "内核已就绪":"内核未就绪").font(.system(size:19,weight:.semibold))
                                Text("当前配置：\(store.activeProfile?.name ?? "尚未导入订阅")").foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        Divider()
                        HStack(spacing:18) {
                            Text("代理模式").fixedSize()
                            Picker("代理模式",selection:Binding(get:{store.database.settings.mode},set:{store.setMode($0)})) {
                                ForEach(RouteMode.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().pickerStyle(.segmented).frame(width:240)
                            Spacer(minLength:0)
                            Toggle("系统代理",isOn:Binding(get:{store.database.settings.systemProxy},set:{store.setNetwork(systemProxy:$0)})).toggleStyle(.switch)
                            Divider().frame(height:24)
                            Toggle("TUN 模式",isOn:Binding(get:{store.database.settings.tun},set:{store.setNetwork(tun:$0)})).toggleStyle(.switch)
                        }.disabled(store.busy)
                    }
                }
                HStack(spacing:14) {
                    Panel {
                        HStack(spacing:14) {
                            IconBadge(icon:"server.rack")
                            VStack(alignment:.leading,spacing:6) {
                                Text("当前节点").font(.caption).foregroundStyle(.secondary)
                                HStack(spacing:10) {
                                    Text(leafNode?.name ?? store.activeNode).font(.system(size:14,weight:.medium)).lineLimit(1)
                                    if let delay = leafNode?.delay { Text("\(delay) ms").foregroundStyle(.green).font(.callout).fixedSize() }
                                }
                                Text(store.database.settings.mode.label+"模式").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength:0)
                        }
                    }
                    Panel {
                        HStack(spacing:14) {
                            IconBadge(icon:"gearshape")
                            VStack(alignment:.leading,spacing:6) {
                                Text("后台服务").font(.caption).foregroundStyle(.secondary)
                                HStack(spacing:7) { StatusDot(active:store.serviceRunning); Text(store.serviceRunning ? "运行中":store.serviceLabel).font(.system(size:14,weight:.medium)).lineLimit(1) }
                            }
                            Spacer(minLength:4)
                            Button("查看设置") { store.settingsTab = "网络"; store.page = .settings }.controlSize(.regular)
                        }.frame(minHeight:58)
                    }
                }
                Panel {
                    VStack(alignment:.leading,spacing:12) {
                        HStack {
                            Text("实时流量").font(.system(size:15,weight:.semibold))
                            Spacer()
                            trafficRate("下载",rate:store.traffic.down,color:LumaPalette.accent)
                            trafficRate("上传",rate:store.traffic.up,color:LumaPalette.upload)
                        }
                        TrafficGraph(samples:store.trafficHistory).frame(height:142)
                        Divider()
                        HStack {
                            total("本次下载",bytes:store.traffic.downTotal ?? 0)
                            Divider().frame(height:34)
                            total("本次上传",bytes:store.traffic.upTotal ?? 0)
                        }
                    }
                }
                Panel {
                    VStack(spacing:10) {
                        HStack(spacing:14) {
                            Image(systemName:"doc.text").font(.system(size:19)).frame(width:28)
                            Text(store.activeProfile?.name ?? "添加你的第一个订阅").font(.system(size:14,weight:.medium)).lineLimit(1)
                            if let updated = store.activeProfile?.lastUpdated { Text("更新于 "+updated.formatted(date:.omitted,time:.shortened)).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button(store.activeProfile == nil ? "添加订阅":"更新订阅") {
                                if let p = store.activeProfile { store.perform { try await store.update(p) } }
                                else { store.page = .subscriptions; store.addingSubscription = true }
                            }.disabled(store.busy)
                        }
                        Divider()
                        HStack(spacing:14) {
                            Image(systemName:"wifi").font(.system(size:19)).frame(width:28)
                            Text("网络检查").font(.system(size:14,weight:.medium))
                            Text(store.coreReady ? "内核可访问":"内核尚未就绪").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("重新检查") { Task { await store.recheck() } }
                        }
                    }
                }
            }.frame(maxWidth:.infinity)
        }
    }
    private func trafficRate(_ title:String,rate:Int64,color:Color)->some View {
        HStack(spacing:7) { Circle().fill(color).frame(width:7,height:7); Text(title); Text(Format.rate(rate)).fontWeight(.medium).monospacedDigit() }.font(.callout).padding(.leading,12)
    }
    private func total(_ title:String,bytes:Int64)->some View {
        VStack(spacing:4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(Format.bytes(bytes)).font(.system(size:17,weight:.medium)).monospacedDigit() }.frame(maxWidth:.infinity)
    }
}

struct TrafficGraph:View {
    var samples:[Traffic]
    private var maximum:Double { max(1024,Double(samples.map { max($0.down,$0.up) }.max() ?? 0)*1.2) }
    private var idle:Bool { samples.allSatisfy { $0.down == 0 && $0.up == 0 } }
    var body:some View {
        HStack(alignment:.top,spacing:10) {
            VStack {
                ForEach((0...3).reversed(),id:\.self) { index in
                    Text(index == 0 ? "0":axisLabel(maximum*Double(index)/3)).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                    if index != 0 { Spacer(minLength:0) }
                }
            }.frame(width:52,height:120,alignment:.trailing)
            VStack(spacing:7) {
                GeometryReader { geo in
                    ZStack {
                        ForEach(0..<4) { index in
                            Path { p in let y=geo.size.height*CGFloat(index)/3; p.move(to:CGPoint(x:0,y:y)); p.addLine(to:CGPoint(x:geo.size.width,y:y)) }.stroke(LumaPalette.border,lineWidth:0.5)
                        }
                        ForEach(0..<7) { index in
                            Path { p in let x=geo.size.width*CGFloat(index)/6; p.move(to:CGPoint(x:x,y:0)); p.addLine(to:CGPoint(x:x,y:geo.size.height)) }.stroke(LumaPalette.border,lineWidth:0.5)
                        }
                        area(size:geo.size).fill(LinearGradient(colors:[LumaPalette.accent.opacity(0.17),LumaPalette.accent.opacity(0.02)],startPoint:.top,endPoint:.bottom))
                        line(size:geo.size,upload:false).stroke(LumaPalette.accent,style:StrokeStyle(lineWidth:1.7,lineJoin:.round))
                        line(size:geo.size,upload:true).stroke(LumaPalette.upload,style:StrokeStyle(lineWidth:1.5,lineJoin:.round))
                        if idle { Text(samples.isEmpty ? "等待内核流量数据":"暂无流量 · 等待代理请求").font(.caption).foregroundStyle(.secondary) }
                    }
                }.frame(height:120)
                HStack { Text("最近 60 次采样"); Spacer(); Text("现在") }.font(.system(size:10)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children:.ignore).accessibilityLabel("实时流量图").accessibilityValue(idle ? "暂无流量":"下载和上传速度随时间变化")
    }
    private func line(size:CGSize,upload:Bool)->Path {
        Path { path in
            for (index,sample) in samples.enumerated() {
                let x=size.width*CGFloat(index)/CGFloat(max(1,samples.count-1))
                let y=size.height*(1-CGFloat(Double(upload ? sample.up:sample.down)/maximum))
                if index == 0 { path.move(to:CGPoint(x:x,y:y)) } else { path.addLine(to:CGPoint(x:x,y:y)) }
            }
        }
    }
    private func axisLabel(_ value:Double)->String {
        let unit = value >= 1024*1024 ? "MB/s":value >= 1024 ? "KB/s":"B/s"
        let divisor:Double = value >= 1024*1024 ? 1024*1024:value >= 1024 ? 1024:1
        return (value/divisor).formatted(.number.precision(.fractionLength(0...1)))+" "+unit
    }
    private func area(size:CGSize)->Path {
        guard !samples.isEmpty else { return Path() }
        var path=line(size:size,upload:false)
        path.addLine(to:CGPoint(x:size.width,y:size.height)); path.addLine(to:CGPoint(x:0,y:size.height)); path.closeSubpath()
        return path
    }
}
