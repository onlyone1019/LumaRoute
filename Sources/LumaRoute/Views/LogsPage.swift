import SwiftUI
import UniformTypeIdentifiers
import LumaRouteCore

struct LogsPage:View {
    @EnvironmentObject var store:AppStore
    @State var search=""
    @State var level="全部级别"
    @State var source="全部来源"
    @State var paused=false
    @State var snapshot:[LogEntry]=[]
    @State var selection:UUID?
    @State var exporting=false
    @State var autoScroll=true
    var items:[LogEntry] { (paused ? snapshot:store.logs).filter { (search.isEmpty || $0.message.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search)) && (level=="全部级别" || $0.level==level) && (source=="全部来源" || $0.source==source) } }
    var selected:LogEntry? { items.first { $0.id==selection } }
    var body:some View {
        VStack(spacing:18) {
            PageHeader(title:"日志") {
                Button { if !paused { snapshot=store.logs }; paused.toggle() } label:{ Label(paused ? "继续":"暂停",systemImage:paused ? "play":"pause") }
                Button { store.logs=[]; snapshot=[] } label:{ Label("清空",systemImage:"trash") }
                Button { exporting=true } label:{ Label("导出诊断",systemImage:"square.and.arrow.up") }
            }
            HStack {
                SearchField(placeholder:"搜索日志",text:$search)
                LumaPicker("日志级别",selection:$level,value:["info":"信息","warning":"警告","error":"错误"][level] ?? level) { Text("全部级别").tag("全部级别"); Text("信息").tag("info"); Text("警告").tag("warning"); Text("错误").tag("error") }.frame(width:150)
                LumaPicker("日志来源",selection:$source,value:source) {
                    Text("全部来源").tag("全部来源")
                    ForEach(Array(Set(store.logs.map(\.source))).sorted(),id:\.self) { Text($0).tag($0) }
                }.frame(width:150)
                Toggle("自动滚动",isOn:$autoScroll).toggleStyle(.checkbox).fixedSize()
            }
            HStack {
                Text("时间").frame(width:95,alignment:.leading)
                Text("级别").frame(width:95,alignment:.leading)
                Text("来源").frame(width:100,alignment:.leading)
                Text("内容").frame(maxWidth:.infinity,alignment:.leading)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,14)
            ScrollViewReader { proxy in
                List(selection:$selection) {
                    ForEach(items) { entry in
                        HStack(alignment:.top) {
                            Text(entry.date.formatted(date:.omitted,time:.standard)).monospacedDigit().frame(width:95,alignment:.leading)
                            HStack { Circle().fill(entry.level=="error" ? .red:entry.level=="warning" ? .orange:.green).frame(width:8,height:8); Text(entry.level=="error" ? "错误":entry.level=="warning" ? "警告":entry.level=="info" ? "信息":entry.level) }.frame(width:95,alignment:.leading)
                            Text(entry.source).frame(width:100,alignment:.leading).lineLimit(1)
                            Text(entry.message).frame(maxWidth:.infinity,alignment:.leading).lineLimit(2)
                        }.font(.system(size:12)).padding(.vertical,4).tag(entry.id).id(entry.id)
                        .contextMenu { Button("复制详情") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.message,forType:.string) } }
                    }
                }.listStyle(.inset)
                .onAppear { if autoScroll && !paused,let id=items.last?.id { proxy.scrollTo(id,anchor:.bottom) } }
                .onChange(of:items.last?.id) { _,id in if autoScroll && !paused,let id { proxy.scrollTo(id,anchor:.bottom) } }
                .onChange(of:autoScroll) { _,enabled in if enabled && !paused,let id=items.last?.id { proxy.scrollTo(id,anchor:.bottom) } }
            }
            if let entry=selected { Panel { VStack(alignment:.leading,spacing:12) { Text("日志详情").font(.headline); Text(entry.message).textSelection(.enabled); HStack { Spacer(); Button("复制详情") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.message,forType:.string) } } } } }
            HStack { Image(systemName:"info.circle").foregroundStyle(.secondary); Text("导出诊断时自动隐藏订阅凭据").font(.caption).foregroundStyle(.secondary); Spacer(); Text("\(items.count) 条日志").font(.caption).foregroundStyle(.secondary) }
        }.fileExporter(isPresented:$exporting,document:DiagnosticsDocument(text:store.logs.map { "\($0.date.ISO8601Format()) [\($0.level)] [\($0.source)] \($0.message)" }.joined(separator:"\n")),contentType:.plainText,defaultFilename:"LumaRoute-diagnostics.txt") { result in if case .failure(let e)=result { store.report(e) } }
    }
}
struct DiagnosticsDocument:FileDocument {
    static var readableContentTypes:[UTType] { [.plainText] }
    var text:String
    init(text:String) { self.text=Redactor.clean(text) }
    init(configuration:ReadConfiguration)throws { text=String(data:configuration.file.regularFileContents ?? Data(),encoding:.utf8) ?? "" }
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper { FileWrapper(regularFileWithContents:Data(text.utf8)) }
}

