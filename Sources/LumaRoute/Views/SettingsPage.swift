import SwiftUI
import UniformTypeIdentifiers
import LumaRouteCore

struct SettingsPage:View {
    @EnvironmentObject var store:AppStore
    @State private var draft=NetworkSettings()
    @State private var restoring=false
    @State private var initialized=false
    var body:some View {
        VStack(spacing:16) {
            PageHeader(title:"设置") {
                Picker("设置分类",selection:$store.settingsTab) { Text("通用").tag("通用"); Text("网络").tag("网络"); Text("更新与备份").tag("更新与备份") }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            ScrollView {
                Group {
                    if store.settingsTab=="网络" { SettingsNetworkTab(draft:$draft) }
                    else if store.settingsTab=="通用" { SettingsGeneralTab(draft:$draft) }
                    else { SettingsMaintenanceTab(restoring:$restoring) }
                }.padding(.bottom,8)
            }
            HStack(spacing:8) {
                Text(draft==store.database.settings ? "设置已保存":"有未应用的设置").font(.system(size:12)).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认设置") { draft=NetworkSettings() }
                Button("应用设置") { let settings=draft; store.perform { try await store.saveSettings(settings) } }.buttonStyle(.borderedProminent).disabled(store.busy || draft==store.database.settings)
            }
        }
        .onAppear { if !initialized { draft=store.database.settings; initialized=true } }
        .onChange(of:store.database.settings) { _,settings in draft=settings }
        .fileImporter(isPresented:$restoring,allowedContentTypes:[.folder]) { result in
            if case .success(let url)=result { store.perform {
                try await store.restoreBackup(url)
            } } else if case .failure(let e)=result { store.report(e) }
        }
    }
}
