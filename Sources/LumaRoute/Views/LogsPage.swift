import SwiftUI
import Observation
import UniformTypeIdentifiers
import LumaRouteCore

@Observable @MainActor final class LogsPageState {
    var search=""
    var level="全部级别"
    var source="全部来源"
    var paused=false
    var snapshot:[LogEntry]=[]
    var selection:UUID?
    var exporting=false
    var autoScroll=true
    var exportDocument:DiagnosticsDocument?
    func prepareExport(_ logs:[LogEntry],coreStatus:String = "尚未运行") {
        exportDocument=DiagnosticsDocument(text:VersionInfo.current.diagnostics(logs:logs,coreStatus:coreStatus))
        exporting=true
    }
    func finishExport() { exporting=false; exportDocument=nil }
}

struct LogsPage:View {
    @EnvironmentObject var store:AppStore
    @State var state=LogsPageState()
    var items:[LogEntry] {
        let logs=state.paused ? state.snapshot:store.logs
        let search=state.search,level=state.level,source=state.source
        guard !search.isEmpty || level != "全部级别" || source != "全部来源" else { return logs }
        return logs.filter { (search.isEmpty || $0.message.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search)) && (level=="全部级别" || $0.level==level) && (source=="全部来源" || $0.source==source) }
    }
    var selected:LogEntry? {
        guard let id=state.selection else { return nil }
        return items.first { $0.id==id }
    }
    var body:some View {
        @Bindable var state=state
        VStack(spacing:16) {
            PageHeader(title:"日志",subtitle:"\(items.count) 条日志") {
                Button { state.snapshot=state.paused ? []:store.logs; state.paused.toggle() } label:{ Label(state.paused ? "继续":"暂停",systemImage:state.paused ? "play":"pause") }
                Button { store.logs=[]; state.snapshot=[] } label:{ Label("清空",systemImage:"trash") }
                Button { state.prepareExport(store.logs,coreStatus:store.coreVersion) } label:{ Label("导出诊断",systemImage:"square.and.arrow.up") }
            }
            HStack(spacing:12) {
                SearchField(placeholder:"搜索日志",text:$state.search)
                LumaPicker("日志级别",selection:$state.level,value:["info":"信息","warning":"警告","error":"错误"][state.level] ?? state.level) { Text("全部级别").tag("全部级别"); Text("信息").tag("info"); Text("警告").tag("warning"); Text("错误").tag("error") }.frame(width:150)
                LumaPicker("日志来源",selection:$state.source,value:state.source) {
                    Text("全部来源").tag("全部来源")
                    ForEach(Array(Set(store.logs.map(\.source))).sorted(),id:\.self) { Text($0).tag($0) }
                }.frame(width:150)
                Toggle("自动滚动",isOn:$state.autoScroll).toggleStyle(.checkbox).fixedSize()
            }
            VStack(spacing:0) {
                HStack(spacing:12) {
                    Text("时间").frame(width:72,alignment:.leading)
                    Text("级别").frame(width:64,alignment:.leading)
                    Text("来源").frame(width:90,alignment:.leading)
                    Text("内容").frame(maxWidth:.infinity,alignment:.leading)
                }.font(.system(size:12)).foregroundStyle(.secondary).padding(.horizontal,16).padding(.top,12).padding(.bottom,4)
                list
            }
            .background(LumaPalette.card,in:RoundedRectangle(cornerRadius:LumaPalette.cardRadius,style:.continuous))
            .clipShape(RoundedRectangle(cornerRadius:LumaPalette.cardRadius,style:.continuous))
            if let entry=selected { Panel { VStack(alignment:.leading,spacing:12) { Text("日志详情").font(.system(size:14,weight:.semibold)); Text(entry.message).textSelection(.enabled); HStack { Spacer(); Button("复制详情") { copy(entry) } } } } }
            HStack(spacing:6) { Image(systemName:"info.circle").foregroundStyle(.secondary); Text("导出诊断时自动隐藏订阅凭据").font(.system(size:12)).foregroundStyle(.secondary); Spacer() }
        }.fileExporter(isPresented:$state.exporting,document:state.exportDocument,contentTypes:[.plainText],defaultFilename:"LumaRoute-diagnostics.txt") { result in
            state.finishExport()
            if case .failure(let e)=result { store.report(e) }
        } onCancellation: { state.finishExport() }
    }
    private var list:some View {
        @Bindable var state=state
        return LogsTableView(rows:items,selection:$state.selection,followsTail:state.autoScroll && !state.paused)
    }

    private func copy(_ entry:LogEntry) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.message,forType:.string) }
}
struct DiagnosticsDocument:FileDocument {
    static var readableContentTypes:[UTType] { [.plainText] }
    var text:String
    init(text:String) { self.text=Redactor.clean(text) }
    init(configuration:ReadConfiguration)throws { text=String(data:configuration.file.regularFileContents ?? Data(),encoding:.utf8) ?? "" }
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper { FileWrapper(regularFileWithContents:Data(text.utf8)) }
}
