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
        VStack(spacing:16) {
            PageHeader(title:"日志",subtitle:"\(items.count) 条日志") {
                Button { if !paused { snapshot=store.logs }; paused.toggle() } label:{ Label(paused ? "继续":"暂停",systemImage:paused ? "play":"pause") }
                Button { store.logs=[]; snapshot=[] } label:{ Label("清空",systemImage:"trash") }
                Button { exporting=true } label:{ Label("导出诊断",systemImage:"square.and.arrow.up") }
            }
            HStack(spacing:12) {
                SearchField(placeholder:"搜索日志",text:$search)
                LumaPicker("日志级别",selection:$level,value:["info":"信息","warning":"警告","error":"错误"][level] ?? level) { Text("全部级别").tag("全部级别"); Text("信息").tag("info"); Text("警告").tag("warning"); Text("错误").tag("error") }.frame(width:150)
                LumaPicker("日志来源",selection:$source,value:source) {
                    Text("全部来源").tag("全部来源")
                    ForEach(Array(Set(store.logs.map(\.source))).sorted(),id:\.self) { Text($0).tag($0) }
                }.frame(width:150)
                Toggle("自动滚动",isOn:$autoScroll).toggleStyle(.checkbox).fixedSize()
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
        }.fileExporter(isPresented:$exporting,document:DiagnosticsDocument(text:store.logs.map { "\($0.date.ISO8601Format()) [\($0.level)] [\($0.source)] \($0.message)" }.joined(separator:"\n")),contentType:.plainText,defaultFilename:"LumaRoute-diagnostics.txt") { result in if case .failure(let e)=result { store.report(e) } }
    }
    private var list:some View {
        ScrollViewReader { proxy in
            List(selection:$selection) {
                ForEach(items) { entry in
                    HStack(alignment:.top,spacing:12) {
                        Text(entry.date.formatted(date:.omitted,time:.standard)).monospacedDigit().foregroundStyle(.secondary).frame(width:72,alignment:.leading)
                        HStack(spacing:6) { Circle().fill(color(entry.level)).frame(width:7,height:7); Text(label(entry.level)) }.frame(width:64,alignment:.leading)
                        Text(entry.source).foregroundStyle(.secondary).frame(width:90,alignment:.leading).lineLimit(1)
                        Text(entry.message).frame(maxWidth:.infinity,alignment:.leading).lineLimit(2)
                    }.font(.system(size:12)).padding(.vertical,5).tag(entry.id).id(entry.id)
                    .listRowSeparator(.hidden).listRowInsets(EdgeInsets(top:0,leading:8,bottom:0,trailing:8))
                    .contextMenu { Button("复制详情") { copy(entry) } }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
            .onAppear { if autoScroll && !paused,let id=items.last?.id { proxy.scrollTo(id,anchor:.bottom) } }
            .onChange(of:items.last?.id) { _,id in if autoScroll && !paused,let id { proxy.scrollTo(id,anchor:.bottom) } }
            .onChange(of:autoScroll) { _,enabled in if enabled && !paused,let id=items.last?.id { proxy.scrollTo(id,anchor:.bottom) } }
        }
    }
    private func color(_ level:String)->Color { level=="error" ? .red:level=="warning" ? .orange:.green }
    private func label(_ level:String)->String { level=="error" ? "错误":level=="warning" ? "警告":level=="info" ? "信息":level }
    private func copy(_ entry:LogEntry) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.message,forType:.string) }
}
struct DiagnosticsDocument:FileDocument {
    static var readableContentTypes:[UTType] { [.plainText] }
    var text:String
    init(text:String) { self.text=Redactor.clean(text) }
    init(configuration:ReadConfiguration)throws { text=String(data:configuration.file.regularFileContents ?? Data(),encoding:.utf8) ?? "" }
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper { FileWrapper(regularFileWithContents:Data(text.utf8)) }
}
