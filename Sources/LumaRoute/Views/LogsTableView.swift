import AppKit
import CoreText
import SwiftUI
import LumaRouteCore

/// Own the table update boundary; retain the original SwiftUI row contents.
/// Visible cells have explicit heights, without List's nested outline diffs.
struct LogsTableView:NSViewRepresentable {
    let rows:[LogEntry]
    @Binding var selection:UUID?
    let followsTail:Bool
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView()
        scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
        let table=Table()
        table.autoresizingMask=[.width]
        table.usesAutomaticRowHeights=true;table.rowSizeStyle = .custom;table.rowHeight=24
        table.intercellSpacing=NSSize(width:17,height:0);table.style = .plain
        table.backgroundColor = .clear;table.headerView=nil;table.gridStyleMask=[]
        table.allowsMultipleSelection=false;table.allowsEmptySelection=true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("log"))
        column.minWidth=0;column.resizingMask = .autoresizingMask;table.addTableColumn(column)
        table.delegate=context.coordinator;table.dataSource=context.coordinator
        table.menuProvider={ [weak c=context.coordinator] row in c?.menu(row) }
        table.widthChanged={ [weak c=context.coordinator] table in c?.resize(table) }
        scroll.documentView=table
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        let appearance:NSAppearance.Name=context.environment.colorScheme == .dark ? .darkAqua:.aqua
        if scroll.appearance?.name != appearance { scroll.appearance=NSAppearance(named:appearance) }
        guard let table=scroll.documentView as? Table else { return }
        context.coordinator.update(self,table)
    }
    @MainActor final class Cell:NSTableCellView {
        let host=NSHostingView(rootView:LogTableRow(entry:LogEntry(source:"",message:"")))
        var height:NSLayoutConstraint!
        override init(frame:NSRect) {
            super.init(frame:frame);host.sizingOptions=[];host.translatesAutoresizingMaskIntoConstraints=false;addSubview(host)
            height=heightAnchor.constraint(equalToConstant:25)
            NSLayoutConstraint.activate([height,host.leadingAnchor.constraint(equalTo:leadingAnchor),host.trailingAnchor.constraint(equalTo:trailingAnchor),host.topAnchor.constraint(equalTo:topAnchor),host.bottomAnchor.constraint(equalTo:bottomAnchor)])
        }
        required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    @MainActor final class Table:NSTableView {
        var menuProvider:((Int)->NSMenu?)?
        var widthChanged:((NSTableView)->Void)?
        var resizeScheduled=false
        override func setFrameSize(_ newSize:NSSize) {
            let changed=abs(frame.width-newSize.width)>0.5
            super.setFrameSize(newSize)
            // Never invalidate table geometry from inside its sizing stack.
            if changed,!resizeScheduled {
                resizeScheduled=true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return };self.resizeScheduled=false;self.widthChanged?(self)
                }
            }
        }
        override func menu(for event:NSEvent)->NSMenu? {
            let row=row(at:convert(event.locationInWindow,from:nil))
            return row >= 0 ? menuProvider?(row):nil
        }
    }
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        var parent:LogsTableView
        var displayed:[LogEntry]=[]
        var updating=false
        var lastWidth:CGFloat=0
        var heights:[UUID:(message:String,height:CGFloat)]=[:]
        var tailScheduled=false

        var tail:UUID?
        var following=false
        init(_ parent:LogsTableView) { self.parent=parent }
        func update(_ parent:LogsTableView,_ table:NSTableView) {
            updating=true;defer { updating=false }
            let scroll=parent.followsTail && (!following || tail != parent.rows.last?.id)
            let changed = !displayed.elementsEqual(parent.rows) { lhs,rhs in
                lhs.id==rhs.id && lhs.date==rhs.date && lhs.level==rhs.level && lhs.source==rhs.source && lhs.message==rhs.message
            }
            self.parent=parent
            if changed {
                displayed=parent.rows
                let ids=Set(displayed.map(\.id));heights=heights.filter { ids.contains($0.key) }
                table.reloadData()
            }
            let selected=parent.selection.flatMap { id in displayed.firstIndex { $0.id==id } }
            table.selectRowIndexes(selected.map { IndexSet(integer:$0) } ?? [],byExtendingSelection:false)
            if scroll { followTail(table) }
            tail=displayed.last?.id;following=parent.followsTail
        }
        func resize(_ table:NSTableView) {
            guard abs(lastWidth-table.bounds.width)>0.5 else { return }
            lastWidth=table.bounds.width;heights=[:]
            table.reloadData()
            if parent.followsTail { followTail(table) }
        }
        func followTail(_ table:NSTableView) {
            guard !tailScheduled else { return };tailScheduled=true
            DispatchQueue.main.async { [weak self,weak table] in
                guard let self,let table else { return };self.tailScheduled=false
                guard self.parent.followsTail,!self.displayed.isEmpty else { return }
                // Automatic heights settle during layout. Scroll after that pass,
                // outside every table delegate callback, then align the actual tail.
                table.layoutSubtreeIfNeeded()
                table.scrollRowToVisible(self.displayed.count-1)
                table.layoutSubtreeIfNeeded()
                table.scrollRowToVisible(self.displayed.count-1)
            }
        }
        func numberOfRows(in tableView:NSTableView)->Int { displayed.count }
        func height(_ entry:LogEntry,width:CGFloat)->CGFloat {
            if let cached=heights[entry.id],cached.message==entry.message { return cached.height }
            let font=NSFont.systemFont(ofSize:12)
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:entry.message,attributes:[.font:font]))
            let textWidth=CTLineGetTypographicBounds(line,nil,nil,nil)
            let height:CGFloat=textWidth>max(1,width-295) || entry.message.contains(where: \.isNewline) ? 40:25
            heights[entry.id]=(entry.message,height);return height
        }
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            guard displayed.indices.contains(row) else { return nil }
            let identifier=NSUserInterfaceItemIdentifier("log-cell")
            let root=LogTableRow(entry:displayed[row])
            let cell=(tableView.makeView(withIdentifier:identifier,owner:self) as? Cell) ?? Cell()
            cell.identifier=identifier;cell.host.rootView=root;cell.height.constant=height(displayed[row],width:tableView.bounds.width)
            return cell
        }

        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !updating,let table=notification.object as? NSTableView else { return }
            let id=displayed.indices.contains(table.selectedRow) ? displayed[table.selectedRow].id:nil
            guard id != parent.selection else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let valid=id.flatMap { id in self.displayed.contains(where:{$0.id==id}) ? id:nil }
                if self.parent.selection != valid { self.parent.selection=valid }
            }
        }
        func menu(_ row:Int)->NSMenu? {
            guard displayed.indices.contains(row) else { return nil }
            let menu=NSMenu();let item=NSMenuItem(title:"复制详情",action:#selector(copyRow(_:)),keyEquivalent:"")
            item.target=self;item.representedObject=displayed[row].message;menu.addItem(item);return menu
        }
        @objc func copyRow(_ sender:NSMenuItem) {
            guard let text=sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
        }
    }
}
struct LogTableRow:View {
    let entry:LogEntry
    var body:some View {
        HStack(alignment:.top,spacing:12) {
            Text(entry.date.formatted(date:.omitted,time:.standard)).monospacedDigit().foregroundStyle(.secondary).frame(width:72,alignment:.leading)
            HStack(spacing:6) { Circle().fill(entry.level=="error" ? .red:entry.level=="warning" ? .orange:.green).frame(width:7,height:7); Text(entry.level=="error" ? "错误":entry.level=="warning" ? "警告":entry.level=="info" ? "信息":entry.level) }.frame(width:64,alignment:.leading)
            Text(entry.source).foregroundStyle(.secondary).frame(width:90,alignment:.leading).lineLimit(1)
            Text(entry.message).frame(maxWidth:.infinity,alignment:.leading).lineLimit(2)
        }.font(.system(size:12)).padding(.vertical,5).padding(.horizontal,8)
    }
}
