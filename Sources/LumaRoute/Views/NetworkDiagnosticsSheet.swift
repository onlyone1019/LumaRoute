import SwiftUI
import LumaRouteCore

struct NetworkDiagnosticsSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var checks: [DiagnosticCheck] = []
    @State private var task: Task<Void,Never>?
    @State private var generation = UUID()
    @State private var running = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("网络诊断").font(.title2.bold())
            Text("依次检查内核、当前网络接管、DNS 和通过本机代理的真实访问，不修改配置。点击开始后会访问下方地址。").foregroundStyle(.secondary)
            TextField("测试地址",text:$address).textFieldStyle(LumaTextFieldStyle()).accessibilityLabel("诊断测试地址").disabled(running)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ForEach(checks) { check in
                        Panel(padding:12) {
                            HStack(alignment:.top,spacing:10) {
                                Image(systemName:check.state == .passed ? "checkmark.circle.fill":check.state == .failed ? "xmark.circle.fill":"exclamationmark.triangle.fill").foregroundStyle(check.state == .passed ? .green:check.state == .failed ? .red:.orange)
                                VStack(alignment:.leading,spacing:5) { Text(check.title).font(.headline); Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                            }
                        }
                    }
                    if running { ProgressView("正在检查，最多约 25 秒…").padding(.vertical,14) }
                }
            }.frame(minHeight:230,maxHeight:390)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                if !checks.isEmpty { Text("\(checks.filter { $0.state == .failed }.count) 项失败 · \(checks.filter { $0.state == .warning }.count) 项提示").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("关闭") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if running { Button("取消检查") { cancel() } }
                else { Button(checks.isEmpty ? "开始诊断":"重新诊断",action:start).buttonStyle(.borderedProminent) }
            }
        }.padding(24).frame(width:670)
         .onAppear { address = store.database.settings.testURL }
         .onDisappear { cancel() }
         .onChange(of:store.database.activeProfileID) { _,_ in reset() }
         .onChange(of:store.database.settings) { _,_ in reset() }
    }
    private func cancel() { task?.cancel(); task = nil; generation = UUID(); running = false }
    private func reset() { cancel(); checks = []; failure = "配置已改变，请重新诊断" }
    private func start() {
        do {
            let url = try NetworkDiagnostics.target(address),api = store.api,settings = store.database.settings
            cancel(); checks = []; failure = nil; running = true
            let token = generation
            task = Task {
                defer { if token == generation { running = false; task = nil } }
                do { let result = try await NetworkDiagnostics.run(api:api,settings:settings,url:url); if token == generation,!Task.isCancelled { checks = result } }
                catch is CancellationError {} catch { if token == generation { failure = Redactor.clean(error.localizedDescription) } }
            }
        } catch { failure = Redactor.clean(error.localizedDescription) }
    }
}
