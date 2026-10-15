import SwiftUI
import ServiceManagement
import LumaRouteCore

struct SettingsPage:View {
    @EnvironmentObject var store:AppStore
    @State private var draft=NetworkSettings()
    @State private var restoring=false
    var body:some View {
        VStack(spacing:16) {
            PageHeader(title:"设置") {
                Picker("",selection:$store.settingsTab) { Text("通用").tag("通用"); Text("网络").tag("网络"); Text("更新与备份").tag("更新与备份") }.pickerStyle(.segmented).frame(width:360)
            }
            ScrollView {
                VStack(spacing:16) {
                    if store.settingsTab=="网络" { network }
                    else if store.settingsTab=="通用" {
                        Panel {
                            VStack(alignment:.leading,spacing:12) {
                                Text("启动与外观").font(.headline)
                                NativeRow(title:"登录时启动") { Toggle("",isOn:$draft.autoLaunch).labelsHidden().toggleStyle(.switch) }
                                Divider()
                                NativeRow(title:"启动后连接",detail:"开启后，将恢复上次保存的接管方式") { Toggle("",isOn:$draft.connectOnLaunch).labelsHidden().toggleStyle(.switch) }
                                Divider()
                                NativeRow(title:"外观") { Picker("",selection:$draft.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.frame(width:160) }
                                Divider()
                                NativeRow(title:"测试并发数") { Stepper("\(draft.testConcurrency)",value:$draft.testConcurrency,in:1...16).frame(width:120) }
                                NativeRow(title:"测试目标") { TextField("测试 URL",text:$draft.testURL).textFieldStyle(.roundedBorder).frame(width:340) }
                                NativeRow(title:"代理端口") { TextField("",value:$draft.mixedPort,format:.number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width:90) }
                                NativeRow(title:"控制端口") { TextField("",value:$draft.controllerPort,format:.number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width:90) }
                                Text("连接快捷键：⌘⇧P · 关闭窗口后应用继续在菜单栏运行").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Panel {
                            VStack(alignment:.leading,spacing:14) {
                                Text("版本与维护").font(.headline)
                                NativeRow(title:"LumaRoute",detail:"0.1.0 · 开发版本") { Text("SwiftUI 原生 Mac 客户端").foregroundStyle(.secondary) }
                                Divider()
                                NativeRow(title:"Mihomo",detail:store.coreVersion) {
                                    Button("检查更新") { store.perform { try await store.checkCoreUpdate() } }
                                }
                                if let release = store.availableCore {
                                    HStack {
                                        Text("最新稳定版：\(release.version)").font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("下载并切换") { store.perform { try await store.updateCore() } }.disabled(store.busy || release.version == store.coreVersion)
                                    }
                                }
                                HStack { Text("切换失败保留当前版本，已成功切换的版本可回退。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("回退上次内核") { store.perform { try await store.rollbackCore() } }.disabled(store.busy || !store.canRollbackCore) }
                                Divider()
                                NativeRow(title:"规则数据库",detail:"校验官方 GEO 数据，更新后短暂重启内核") {
                                    Button("回退") { store.perform { try await store.updateGeoData(rollback:true) } }.disabled(store.busy || !store.coreReady || !store.canRollbackGeo)
                                    Button("更新") { store.perform { try await store.updateGeoData() } }.disabled(store.busy || !store.coreReady)
                                }
                            }
                        }
                        Panel {
                            VStack(alignment:.leading,spacing:14) {
                                Text("本地备份").font(.headline)
                                Text("备份包含订阅配置、规则和设置。完整订阅链接和控制密钥留在本机，不包含在备份中。").font(.caption).foregroundStyle(.secondary)
                                HStack { Button("创建备份") { store.perform { try await store.backup() } }; Button("恢复备份…") { restoring=true } }
                            }
                        }
                    }
                }
            }
            HStack { Text(draft==store.database.settings ? "设置已保存":"有未应用的设置").font(.caption).foregroundStyle(.secondary); Spacer(); Button("恢复默认设置") { draft=NetworkSettings() }; Button("应用设置") { let settings=draft; store.perform { try await store.saveSettings(settings) } }.buttonStyle(LumaPrimaryButtonStyle()).disabled(store.busy || draft==store.database.settings) }
        }
        .onAppear { draft=store.database.settings }
        .onChange(of:store.database.settings) { _,settings in draft=settings }
        .fileImporter(isPresented:$restoring,allowedContentTypes:[.folder]) { result in
            if case .success(let url)=result { store.perform {
                try await store.restoreBackup(url)
            } } else if case .failure(let e)=result { store.report(e) }
        }
    }
    var network:some View {
        VStack(spacing:12) {
            Panel(padding:12) {
                VStack(alignment:.leading,spacing:5) {
                    Text("系统代理").font(.headline)
                    NativeRow(title:"系统代理",detail:"让遵循系统代理的应用通过代理连接",compact:true) { Toggle("",isOn:$draft.systemProxy).labelsHidden().toggleStyle(.switch) }
                    Divider()
                    NativeRow(title:"绕过地址",compact:true) { TextField("",text:Binding(get:{draft.bypass.joined(separator:", ")},set:{draft.bypass=$0.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }})).textFieldStyle(.roundedBorder).frame(width:400) }
                }
            }
            Panel(padding:12) {
                VStack(alignment:.leading,spacing:5) {
                    Text("TUN 模式").font(.headline)
                    NativeRow(title:"启用 TUN",detail:"接管未使用系统代理的应用流量",compact:true) { Toggle("",isOn:$draft.tun).labelsHidden().toggleStyle(.switch) }
                    Divider()
                    NativeRow(title:"后台服务",detail:"首次启用需要管理员授权",compact:true) {
                        StatusDot(active:store.serviceRunning)
                        Text(store.serviceInstalling ? "正在准备…":store.serviceRunning ? "已授权 · 运行中":store.serviceLabel).foregroundStyle(.secondary)
                        if store.serviceSetup != .ready {
                            Button(store.serviceSetupButton) { store.installService(networkReady:true) }.disabled(store.busy || store.serviceInstalling)
                        }
                        Menu("管理服务") {
                            Button("重新同步服务") { store.installService(networkReady:true) }.disabled(store.serviceInstalling)
                            Button("仅验证服务启动") { store.installService() }.disabled(store.serviceInstalling)
                            if store.helper.supportsPrivilegedService && store.helper.localInstallation == nil {
                                Button("打开授权设置") { store.helper.openApproval() }
                            }
                            Button("卸载服务",role:.destructive) { store.uninstallService() }
                        }.frame(width:110)
                    }
                    Divider()
                    NativeRow(title:"协议栈",compact:true) { Picker("",selection:$draft.stack) { Text("Mixed").tag("mixed"); Text("System").tag("system"); Text("gVisor").tag("gvisor"); Text("MIPS").tag("mips") }.frame(width:150) }
                    NativeRow(title:"自动设置路由",compact:true) { Toggle("",isOn:$draft.autoRoute).labelsHidden().toggleStyle(.switch) }
                    NativeRow(title:"自动识别出口网卡",compact:true) { Toggle("",isOn:$draft.autoDetectInterface).labelsHidden().toggleStyle(.switch) }
                    NativeRow(title:"排除局域网地址",detail:"保持本地设备可访问",compact:true) { Toggle("",isOn:$draft.excludeLAN).labelsHidden().toggleStyle(.switch) }
                    NativeRow(title:"MTU",compact:true) { TextField("",value:$draft.mtu,format:.number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width:90) }
                    NativeRow(title:"IPv6",compact:true) { Toggle("",isOn:$draft.ipv6).labelsHidden().toggleStyle(.switch) }
                }
            }
            Panel(padding:12) {
                VStack(alignment:.leading,spacing:5) {
                    Text("DNS").font(.headline)
                    NativeRow(title:"DNS 接管",compact:true) { Toggle("",isOn:$draft.dnsHijack).labelsHidden().toggleStyle(.switch) }
                    NativeRow(title:"解析模式",compact:true) { Picker("",selection:$draft.fakeIP) { Text("Fake-IP").tag(true); Text("真实 IP").tag(false) }.frame(width:150) }
                    NativeRow(title:"系统 DNS",detail:"关闭 TUN 时恢复；不会覆盖其他软件后续的修改",compact:true) { Text(store.database.settings.tun ? "由授权服务管理":"未修改").foregroundStyle(.secondary) }
                }
            }
            HStack { StatusDot(active:store.coreReady); Text(store.coreReady ? "内核运行正常":"内核尚未就绪").foregroundStyle(.secondary); Spacer(); Button("重新检查") { Task { await store.recheck() } } }.font(.caption)
        }.font(.system(size:12)).controlSize(.small)
    }
}

