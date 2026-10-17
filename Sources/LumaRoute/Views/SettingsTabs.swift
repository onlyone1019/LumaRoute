import SwiftUI
import LumaRouteCore

struct SettingsGeneralTab:View {
    @Binding var draft:NetworkSettings
    var body:some View {
        VStack(spacing:18) {
            SettingsGroup(title:"启动与外观") {
                NativeRow(title:"登录时启动") { Toggle("登录时启动",isOn:$draft.autoLaunch).labelsHidden().toggleStyle(.switch) }
                RowDivider()
                NativeRow(title:"启动后连接",detail:"开启后，将恢复上次保存的接管方式") { Toggle("启动后连接",isOn:$draft.connectOnLaunch).labelsHidden().toggleStyle(.switch) }
                RowDivider()
                NativeRow(title:"外观") { LumaPicker("外观",selection:$draft.appearance,value:["system":"跟随系统","light":"浅色","dark":"深色"][draft.appearance] ?? draft.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.frame(width:160) }
            }
            SettingsGroup(title:"测速与端口") {
                NativeRow(title:"测试并发数") { Stepper("\(draft.testConcurrency)",value:$draft.testConcurrency,in:1...16).fixedSize() }
                RowDivider()
                NativeRow(title:"测试目标") { TextField("测试 URL",text:$draft.testURL).textFieldStyle(LumaTextFieldStyle()).frame(width:340) }
                RowDivider()
                NativeRow(title:"代理端口") { TextField("",value:$draft.mixedPort,format:.number.grouping(.never)).textFieldStyle(LumaTextFieldStyle()).accessibilityLabel("代理端口").frame(width:90) }
                RowDivider()
                NativeRow(title:"控制端口") { TextField("",value:$draft.controllerPort,format:.number.grouping(.never)).textFieldStyle(LumaTextFieldStyle()).accessibilityLabel("控制端口").frame(width:90) }
            }
            Text("连接快捷键：⌘⇧P · 关闭窗口后应用继续在菜单栏运行").font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(.leading,6)
        }
    }
}

struct SettingsNetworkTab:View {
    @EnvironmentObject var store:AppStore
    @Binding var draft:NetworkSettings
    var body:some View {
        VStack(spacing:18) {
            SettingsGroup(title:"系统代理") {
                NativeRow(title:"启用系统代理",detail:"让遵循系统代理的应用通过代理连接",compact:true) { Toggle("系统代理",isOn:$draft.systemProxy).labelsHidden().toggleStyle(.switch) }
                RowDivider()
                VStack(alignment:.leading,spacing:8) {
                    Text("绕过地址").font(.system(size:14))
                    TextField("",text:Binding(get:{draft.bypass.joined(separator:", ")},set:{draft.bypass=$0.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }})).textFieldStyle(LumaTextFieldStyle()).accessibilityLabel("绕过地址")
                }.padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading)
            }
            SettingsGroup(title:"TUN 模式") {
                NativeRow(title:"启用 TUN",detail:"接管未使用系统代理的应用流量",compact:true) { Toggle("启用 TUN",isOn:$draft.tun).labelsHidden().toggleStyle(.switch) }
                RowDivider()
                NativeRow(title:"后台服务",detail:"首次启用需要管理员授权",compact:true) {
                    StatusDot(active:store.serviceRunning)
                    Text(store.serviceInstalling ? "正在准备…":store.serviceRunning ? "已授权 · 运行中":store.serviceLabel).foregroundStyle(.secondary)
                    if store.serviceSetup != .ready {
                        Button(store.serviceSetupButton) { store.installService(networkReady:true) }.disabled(store.busy || store.serviceInstalling)
                    }
                    LumaMenu(title:"管理服务") {
                        Button("重新同步服务") { store.installService(networkReady:true) }.disabled(store.serviceInstalling)
                        Button("仅验证服务启动") { store.installService() }.disabled(store.serviceInstalling)
                        if store.helper.supportsPrivilegedService && store.helper.localInstallation == nil {
                            Button("打开授权设置") { store.helper.openApproval() }
                        }
                        Button("卸载服务",role:.destructive) { store.uninstallService() }
                    }.frame(width:130)
                }
                RowDivider()
                NativeRow(title:"协议栈",compact:true) { LumaPicker("协议栈",selection:$draft.stack,value:["mixed":"Mixed","system":"System","gvisor":"gVisor","mips":"MIPS"][draft.stack] ?? draft.stack) { Text("Mixed").tag("mixed"); Text("System").tag("system"); Text("gVisor").tag("gvisor"); Text("MIPS").tag("mips") }.frame(width:150) }
                RowDivider()
                NativeRow(title:"自动设置路由",compact:true) { Toggle("自动设置路由",isOn:$draft.autoRoute).labelsHidden().toggleStyle(.switch) }
                RowDivider()
                NativeRow(title:"自动识别出口网卡",compact:true) { Toggle("自动识别出口网卡",isOn:$draft.autoDetectInterface).labelsHidden().toggleStyle(.switch) }
                RowDivider()
                NativeRow(title:"排除局域网地址",detail:"保持本地设备可访问",compact:true) { Toggle("排除局域网地址",isOn:$draft.excludeLAN).labelsHidden().toggleStyle(.switch) }
                RowDivider()
                NativeRow(title:"MTU",compact:true) { TextField("",value:$draft.mtu,format:.number.grouping(.never)).textFieldStyle(LumaTextFieldStyle()).accessibilityLabel("MTU").frame(width:90) }
                RowDivider()
                NativeRow(title:"IPv6",compact:true) { Toggle("IPv6",isOn:$draft.ipv6).labelsHidden().toggleStyle(.switch) }
            }
            SettingsGroup(title:"DNS") {
                NativeRow(title:"DNS 接管",compact:true) { Toggle("DNS 接管",isOn:$draft.dnsHijack).labelsHidden().toggleStyle(.switch) }
                RowDivider()
                NativeRow(title:"解析模式",compact:true) { LumaPicker("解析模式",selection:$draft.fakeIP,value:draft.fakeIP ? "Fake-IP":"真实 IP") { Text("Fake-IP").tag(true); Text("真实 IP").tag(false) }.frame(width:150) }
                RowDivider()
                NativeRow(title:"系统 DNS",detail:"关闭 TUN 时恢复；不会覆盖其他软件后续的修改",compact:true) { Text(store.database.settings.tun ? "由授权服务管理":"未修改").foregroundStyle(.secondary) }
            }
            HStack(spacing:8) {
                StatusDot(active:store.coreReady); Text(store.coreReady ? "内核运行正常":"内核尚未就绪").foregroundStyle(.secondary)
                Spacer(); Button("重新检查") { Task { await store.recheck() } }
            }.font(.system(size:12)).padding(.horizontal,6)
        }
    }
}

struct SettingsMaintenanceTab:View {
    @EnvironmentObject var store:AppStore
    @Binding var restoring:Bool
    var body:some View {
        VStack(spacing:18) {
            SettingsGroup(title:"版本与维护") {
                NativeRow(title:"LumaRoute",detail:store.applicationVersion?.label ?? "开发版本") {
                    Button(store.checkingAppUpdate ? "更新进行中…":"检查更新") { Task { await store.checkAppUpdate() } }.disabled(store.checkingAppUpdate)
                }
                if let message = store.appUpdateMessage {
                    RowDivider()
                    NativeRow(title:"应用更新",detail:message) { EmptyView() }
                }
                RowDivider()
                NativeRow(title:"Mihomo",detail:store.coreVersion) {
                    Button("检查更新") { store.perform { try await store.checkCoreUpdate() } }
                }
                if let release = store.availableCore {
                    RowDivider()
                    NativeRow(title:"最新稳定版",detail:release.version) {
                        Button("下载并切换") { store.perform { try await store.updateCore() } }.disabled(store.busy || release.version == store.coreVersion)
                    }
                }
                RowDivider()
                NativeRow(title:"回退内核",detail:"切换失败保留当前版本，已成功切换的版本可回退。") {
                    Button("回退上次内核") { store.perform { try await store.rollbackCore() } }.disabled(store.busy || !store.canRollbackCore)
                }
                RowDivider()
                NativeRow(title:"规则数据库",detail:"校验在线 GEO 数据，保留已审核的服务分类；更新后短暂重启内核") {
                    Button("回退") { store.perform { try await store.updateGeoData(rollback:true) } }.disabled(store.busy || !store.coreReady || !store.canRollbackGeo)
                    Button("更新") { store.perform { try await store.updateGeoData() } }.disabled(store.busy || !store.coreReady)
                }
            }
            SettingsGroup(title:"本地备份") {
                NativeRow(title:"备份与恢复",detail:"备份包含订阅配置、规则和设置。完整订阅链接和控制密钥留在本机，不包含在备份中。") {
                    Button("创建备份") { store.perform { try await store.backup() } }
                    Button("恢复备份…") { restoring=true }
                }
            }
        }
    }
}
