import AppKit
import SwiftUI
import LumaRouteCore

/// Own the table, as on the connections page: SwiftUI's automatic row-height
/// measurement retains expensive row content while scrolling large rule sets.
struct LiveRulesTableView:NSViewRepresentable {
    let rows:[LiveRule]

    func makeCoordinator()->Coordinator { Coordinator() }
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView()
        scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
        scroll.autohidesScrollers=true;scroll.drawsBackground=false
        let table=NSTableView()
        table.autoresizingMask=[.width]
        table.usesAutomaticRowHeights=false;table.rowSizeStyle = .custom;table.rowHeight=24
        table.intercellSpacing=NSSize(width:17,height:0)
        table.style = .inset;table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors=false;table.gridStyleMask = []
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (index,title) in ["类型","匹配内容","目标策略"].enumerated() {
            let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(String(index)))
            column.title=title
            if index == 1 {
                column.minWidth=100;column.width=400
                column.resizingMask=[.autoresizingMask,.userResizingMask]
            } else {
                let width:CGFloat=index == 0 ? 150:180
                column.minWidth=width;column.maxWidth=width;column.width=width;column.resizingMask=[]
            }
            table.addTableColumn(column)
        }
        table.delegate=context.coordinator;table.dataSource=context.coordinator
        scroll.documentView=table
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        scroll.appearance=NSAppearance(named:context.environment.colorScheme == .dark ? .darkAqua:.aqua)
        guard let table=scroll.documentView as? NSTableView else { return }
        context.coordinator.update(rows,table:table)
    }

    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        private var displayed:[LiveRule]=[]
        func update(_ rows:[LiveRule],table:NSTableView) {
            guard displayed != rows else { return }
            displayed=rows
            table.reloadData()
        }
        func numberOfRows(in tableView:NSTableView)->Int { displayed.count }
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            guard displayed.indices.contains(row),let tableColumn else { return nil }
            let cell:NSTableCellView
            if let reused=tableView.makeView(withIdentifier:tableColumn.identifier,owner:self) as? NSTableCellView { cell=reused }
            else {
                cell=NSTableCellView();cell.identifier=tableColumn.identifier
                let label=NSTextField(labelWithString:"")
                label.font = .systemFont(ofSize:13);label.textColor = .labelColor
                label.lineBreakMode = .byTruncatingTail;label.maximumNumberOfLines=1
                label.translatesAutoresizingMaskIntoConstraints=false
                cell.addSubview(label);cell.textField=label
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:cell.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo:cell.trailingAnchor),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            }
            let rule=displayed[row]
            let text:String
            switch tableColumn.identifier.rawValue { case "0":text=rule.type;case "1":text=rule.payload;default:text=rule.proxy }
            cell.textField?.stringValue=text;cell.toolTip=text
            return cell
        }
        func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {
            let identifier=NSUserInterfaceItemIdentifier("live-rule-row")
            if let reused=tableView.makeView(withIdentifier:identifier,owner:self) as? NSTableRowView { return reused }
            let view=RowView();view.identifier=identifier
            return view
        }
    }
    @MainActor private final class RowView:NSTableRowView {
        override func draw(_ dirtyRect:NSRect) {
            super.draw(dirtyRect)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSRect(x:0,y:bounds.maxY-0.5,width:bounds.width,height:0.5).fill()
        }
    }
}
