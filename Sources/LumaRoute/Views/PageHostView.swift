import AppKit
import SwiftUI

/// Retain visited SwiftUI pages, but attach only the active page to the window.
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
    func show(_ page: AppPage,store: AppStore) {
        if owner !== store {
            subviews.forEach { $0.removeFromSuperview() }
            pages.removeAll(); current = nil; owner = store
        }
        guard current != page else { return }
        window?.makeFirstResponder(nil)
        subviews.forEach { $0.removeFromSuperview() }
        let hosted: NSHostingView<AnyView>
        if let cached = pages[page] { hosted = cached }
        else {
            hosted = NSHostingView(rootView:AnyView(HostedPage(page:page).environmentObject(store)))
            // The outer SwiftUI layout supplies our bounds. Avoid measuring
            // each page at minimum, ideal and maximum sizes on every switch.
            hosted.sizingOptions = []
            hosted.autoresizingMask = [.width,.height]
            pages[page] = hosted
        }
        hosted.frame = bounds
        addSubview(hosted)
        current = page
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
    var body: some View {
        Group {
            switch page {
            case .overview: OverviewPage()
            case .subscriptions: SubscriptionsPage()
            case .proxies: ProxiesPage()
            case .connections: ConnectionsPage()
            case .rules: RulesPage()
            case .logs: LogsPage()
            case .settings: SettingsPage()
            }
        }
        .tint(LumaPalette.accent).buttonStyle(.bordered).controlSize(.regular)
        .environment(\.colorScheme,store.database.settings.appearance == "light" ? .light:store.database.settings.appearance == "dark" ? .dark:systemColorScheme)
    }
}
