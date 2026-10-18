import AppKit
import SwiftUI
import LumaRouteCore

/// Own the native table from creation so SwiftUI cannot re-enable automatic
/// row sizing during reconstruction. SwiftUI still owns filtering, sorting,
/// selection and rule creation; the coordinator holds only the displayed snapshot.
struct ConnectionTableView:NSViewRepresentable {
    let rows:[LiveConnection]
    @Binding var selection:String?
    @Binding var sortOrder:[KeyPathComparator<LiveConnection>]
    let targets:[(name:String,label:String)]
    let canCreateRule:Bool
    let createRule:(LiveConnection,Bool,String)->Void

    func makeCoordinator()->Coordinator { Coordinator(parent:self) }
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView()
        scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
        scroll.autohidesScrollers=true;scroll.drawsBackground=false
        let table=Table()
        table.autoresizingMask=[.width]
        table.usesAutomaticRowHeights=false;table.rowSizeStyle = .custom;table.rowHeight=24
        table.intercellSpacing=NSSize(width:17,height:0)
        table.style = .inset;table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors=false
        table.gridStyleMask = []
        table.allowsMultipleSelection=false;table.allowsEmptySelection=true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for column in Column.allCases {
            let native=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(column.rawValue))
            native.title=column.title;native.minWidth=column.minimum;native.width=column.ideal
            if column.fixed { native.maxWidth=column.ideal;native.resizingMask=[] }
            else { native.maxWidth=CGFloat.greatestFiniteMagnitude;native.resizingMask=[.autoresizingMask,.userResizingMask] }
            native.sortDescriptorPrototype=NSSortDescriptor(key:column.rawValue,ascending:true)
            table.addTableColumn(native)
        }
        table.delegate=context.coordinator;table.dataSource=context.coordinator
        table.contextMenuProvider={ [weak coordinator=context.coordinator] row in coordinator?.menu(for:row) }
        scroll.documentView=table
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        scroll.appearance=NSAppearance(named:context.environment.colorScheme == .dark ? .darkAqua:.aqua)
        guard let table=scroll.documentView as? Table else { return }
        context.coordinator.update(self,table:table)
    }

    private enum Column:String,CaseIterable {
        case process,target,policy,download,upload
        var title:String { switch self { case .process:"进程";case .target:"目标";case .policy:"策略";case .download:"下载";case .upload:"上传" } }
        var minimum:CGFloat { switch self { case .process:70;case .target:110;case .policy:80;case .download:75;case .upload:70 } }
        var ideal:CGFloat { switch self { case .process:90;case .target:150;case .policy:110;case .download:75;case .upload:70 } }
        var fixed:Bool { self == .download || self == .upload }
        var keyPath:PartialKeyPath<LiveConnection> { switch self {
            case .process:\LiveConnection.processName;case .target:\LiveConnection.target;case .policy:\LiveConnection.policyName
            case .download:\LiveConnection.download;case .upload:\LiveConnection.upload
        } }
        func comparator(_ order:SortOrder)->KeyPathComparator<LiveConnection> {
            switch self {
            case .process:KeyPathComparator(\LiveConnection.processName,order:order)
            case .target:KeyPathComparator(\LiveConnection.target,order:order)
            case .policy:KeyPathComparator(\LiveConnection.policyName,order:order)
            case .download:KeyPathComparator(\LiveConnection.download,order:order)
            case .upload:KeyPathComparator(\LiveConnection.upload,order:order)
            }
        }
        func text(_ row:LiveConnection)->String { switch self {
            case .process:row.processName;case .target:row.target;case .policy:row.policyName
            case .download:Format.bytes(row.download);case .upload:Format.bytes(row.upload)
        } }
    }
    @MainActor final class Table:NSTableView {
        var contextMenuProvider:((Int)->NSMenu?)?
        override func menu(for event:NSEvent)->NSMenu? {
            let row=row(at:convert(event.locationInWindow,from:nil))
            guard row >= 0 else { return nil }
            selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            return contextMenuProvider?(row)
        }
    }
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        var parent:ConnectionTableView
        private var displayed:[LiveConnection]=[]
        private var updating=false
        init(parent:ConnectionTableView) { self.parent=parent }
        func update(_ parent:ConnectionTableView,table:NSTableView) {
            updating=true;defer { updating=false }
            self.parent=parent;displayed=parent.rows
            let descriptors=parent.sortOrder.compactMap { comparator -> NSSortDescriptor? in
                guard let column=Column.allCases.first(where:{$0.keyPath == comparator.keyPath}) else { return nil }
                return NSSortDescriptor(key:column.rawValue,ascending:comparator.order == .forward)
            }
            if table.sortDescriptors != descriptors { table.sortDescriptors=descriptors }
            table.reloadData()
            let selected=parent.selection.flatMap { id in displayed.firstIndex { $0.id == id } }
            table.selectRowIndexes(selected.map { IndexSet(integer:$0) } ?? [],byExtendingSelection:false)
        }
        func numberOfRows(in tableView:NSTableView)->Int { displayed.count }
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            guard displayed.indices.contains(row),let tableColumn,let column=Column(rawValue:tableColumn.identifier.rawValue) else { return nil }
            let cell:NSTableCellView
            if let reused=tableView.makeView(withIdentifier:tableColumn.identifier,owner:self) as? NSTableCellView { cell=reused }
            else {
                cell=NSTableCellView();cell.identifier=tableColumn.identifier
                let label=NSTextField(labelWithString:"")
                label.font=column.fixed ? .monospacedDigitSystemFont(ofSize:13,weight:.regular):.systemFont(ofSize:13)
                label.textColor = .labelColor
                label.lineBreakMode = .byTruncatingTail;label.maximumNumberOfLines=1
                label.translatesAutoresizingMaskIntoConstraints=false
                cell.addSubview(label);cell.textField=label
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:0),
                    label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:0),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            }
            let text=column.text(displayed[row]);cell.textField?.stringValue=text;cell.toolTip=text
            return cell
        }
        func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {
            let identifier=NSUserInterfaceItemIdentifier("connection-row")
            if let reused=tableView.makeView(withIdentifier:identifier,owner:self) as? NSTableRowView { return reused }
            let view=RowView();view.identifier=identifier
            return view
        }
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !updating,let table=notification.object as? NSTableView else { return }
            let id=displayed.indices.contains(table.selectedRow) ? displayed[table.selectedRow].id:nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.selection=id.flatMap { id in self.displayed.contains(where:{$0.id == id}) ? id:nil }
            }
        }
        func tableView(_ tableView:NSTableView,sortDescriptorsDidChange oldDescriptors:[NSSortDescriptor]) {
            guard !updating else { return }
            let order=tableView.sortDescriptors.compactMap { descriptor -> KeyPathComparator<LiveConnection>? in
                guard let key=descriptor.key,let column=Column(rawValue:key) else { return nil }
                return column.comparator(descriptor.ascending ? .forward:.reverse)
            }
            DispatchQueue.main.async { [weak self] in self?.parent.sortOrder=order }
        }
        func menu(for row:Int)->NSMenu? {
            guard displayed.indices.contains(row) else { return nil }
            let connection=displayed[row];let menu=NSMenu()
            for (title,application) in [("此域名以后走",false),("此应用以后走",true)] {
                let item=NSMenuItem(title:title,action:nil,keyEquivalent:"")
                let options=NSMenu()
                for target in parent.targets {
                    let action=MenuAction { [weak self] in
                        guard let self,self.parent.canCreateRule else { return }
                        self.parent.createRule(connection,application,target.name)
                    }
                    let option=NSMenuItem(title:target.label,action:#selector(MenuAction.invokeMenuItem(_:)),keyEquivalent:"")
                    option.target=action;option.representedObject=action;options.addItem(option)
                }
                item.submenu=options
                item.isEnabled=parent.canCreateRule && (!application || connection.metadata.process?.isEmpty == false || connection.metadata.processPath?.isEmpty == false)
                menu.addItem(item)
            }
            menu.autoenablesItems=false
            return menu
        }
    }
    @MainActor private final class RowView:NSTableRowView {
        override func draw(_ dirtyRect:NSRect) {
            super.draw(dirtyRect)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSRect(x:0,y:bounds.maxY-0.5,width:bounds.width,height:0.5).fill()
        }
    }
    @MainActor private final class MenuAction:NSObject {
        let action:()->Void
        init(_ action:@escaping ()->Void) { self.action=action }
        @objc func invokeMenuItem(_ sender:NSMenuItem) { action() }
    }
}
