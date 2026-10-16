import AppKit
import SwiftUI

/// Keep quick return navigation warm; reclaim inactive live-data pages after idle.
/// The bridge owns view lifetime; AppStore still owns navigation and business data.
struct PageHostView: NSViewRepresentable {
    @EnvironmentObject var store: AppStore
    func makeNSView(context: Context) -> PageContainerView { PageContainerView() }
    func updateNSView(_ view: PageContainerView,context: Context) { view.show(store.page,store:store) }
}

@MainActor final class PageContainerView: NSView {
    private var pages: [AppPage:NSHostingView<AnyView>] = [:]
    private var current: AppPage?
    private weak var owner: AppStore?
    private var evictionTask: Task<Void,Never>?
    private var scrollPositions: [AppPage:NSPoint] = [:]
    private var connectionColumnWidths: [CGFloat] = []
    private(set) var logsState = LogsPageState()
    private(set) var connectionsState = ConnectionsPageState()
    deinit { evictionTask?.cancel() }
    func show(_ page: AppPage,store: AppStore) {
        if owner !== store {
            evictionTask?.cancel()
            subviews.forEach { $0.removeFromSuperview() }
            pages.removeAll(); scrollPositions.removeAll(); connectionColumnWidths=[]
            logsState=LogsPageState(); connectionsState=ConnectionsPageState()
            current = nil; owner = store
        }
        guard current != page else { return }
        window?.makeFirstResponder(nil)
        if let current,let hosted=pages[current],current == .logs || current == .connections,
           let scroll=scrollView(in:hosted) {
            scrollPositions[current]=scroll.contentView.bounds.origin
            if current == .connections,let table=scroll.documentView as? NSTableView {
                connectionColumnWidths=table.tableColumns.map(\.width)
            }
        }
        subviews.forEach { $0.removeFromSuperview() }
        let hosted: NSHostingView<AnyView>
        let rebuilding = pages[page] == nil
        if let cached = pages[page] { hosted = cached }
        else {
            hosted = NSHostingView(rootView:AnyView(HostedPage(page:page,logsState:logsState,connectionsState:connectionsState).environmentObject(store)))
            // The outer SwiftUI layout supplies our bounds. Avoid measuring
            // each page at minimum, ideal and maximum sizes on every switch.
            hosted.sizingOptions = []
            hosted.autoresizingMask = [.width,.height]
            pages[page] = hosted
        }
        hosted.frame = bounds
        addSubview(hosted)
        current = page
        if rebuilding,let origin=scrollPositions[page],page == .connections || (page == .logs && !logsState.autoScroll) {
            hosted.layoutSubtreeIfNeeded()
            if let scroll=scrollView(in:hosted) {
                if page == .connections,let table=scroll.documentView as? NSTableView {
                    for (column,width) in zip(table.tableColumns,connectionColumnWidths) { column.width=width }
                }
                scroll.contentView.scroll(to:origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        evictionTask?.cancel()
        evictionTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:60_000_000_000) } catch { return }
            self?.releaseInactivePages()
        }
    }
    func releaseInactivePages() {
        // Editing pages stay intact so drafts, expanded groups and focus survive.
        // The small state objects outlive these two disposable rendering trees.
        if current != .logs && !logsState.exporting { pages.removeValue(forKey:.logs) }
        if current != .connections && connectionsState.routingRule == nil { pages.removeValue(forKey:.connections) }
    }
    private func scrollView(in view:NSView) -> NSScrollView? {
        if let scroll=view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in:$0) }.first
    }
    override func layout() {
        super.layout()
        if let hosted = subviews.first,hosted.frame != bounds { hosted.frame = bounds }
    }
}

private struct HostedPage: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var systemColorScheme
    let page: AppPage
    let logsState: LogsPageState
    let connectionsState: ConnectionsPageState
    var body: some View {
        Group {
            switch page {
            case .overview: OverviewPage()
            case .subscriptions: SubscriptionsPage()
            case .proxies: ProxiesPage()
            case .connections: ConnectionsPage(state:connectionsState)
            case .rules: RulesPage()
            case .logs: LogsPage(state:logsState)
            case .settings: SettingsPage()
            }
        }
        .controlSize(.large)
        .environment(\.colorScheme,store.database.settings.appearance == "light" ? .light:store.database.settings.appearance == "dark" ? .dark:systemColorScheme)
    }
}
