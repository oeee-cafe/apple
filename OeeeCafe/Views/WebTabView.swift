import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The search tab: the native search field, with the site's results below it.
struct SearchTabView: View {
    let controller: WebTabController
    @State private var query = ""
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            ZStack {
                WebTabView(controller: controller)
                    .ignoresSafeArea(.container)
                    .unreachable(controller)
                if !hasSearched {
                    // Nothing searched for yet: the site's own ground, not the system's,
                    // over the whole of the tab -- the strip behind the clock with it.
                    ContentUnavailableView("tab.search".localized, systemImage: "magnifyingglass")
                        .background(Color("Ground").ignoresSafeArea())
                }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .searchable(text: $query)
        .onSubmit(of: .search) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            hasSearched = true
            controller.search(trimmed)
        }
    }
}

/// Shows a tab's web view. The web view outlives this view, so it is hosted in a container
/// rather than handed to SwiftUI directly.
#if os(macOS)
struct WebTabView: NSViewRepresentable {
    let controller: WebTabController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if controller.webView.superview !== container {
            attach(to: container)
        }
    }
}
#else
/// The container fills the screen, but the web view stops at the status bar: a page pulled
/// down to refresh moves below it, with the spinner between, rather than under the Dynamic
/// Island. Behind the status bar is NEO's ground, which is what the site lays its pages on
/// (`--ds-ground`, ds.css in oeee-cafe/web), so at rest the two read as one.
struct WebTabView: UIViewRepresentable {
    let controller: WebTabController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if controller.webView.superview !== container {
            attach(to: container)
        }
    }
}
#endif

extension WebTabView {
    private func attach(to container: PlatformView) {
        let webView = controller.webView
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        #if os(macOS)
        let top = container.topAnchor
        #else
        // The web view draws no ground of its own (WebTabController), so this is what shows
        // behind the status bar, in whichever of the two the site's theme put the window in
        // (SiteTheme). Not the web view's `underPageBackgroundColor`: a web view that draws
        // no background has none to give -- it is transparent, and stays so -- so asking it
        // left the strip behind the clock black.
        container.backgroundColor = UIColor(named: "Ground")
        let top = container.safeAreaLayoutGuide.topAnchor
        #endif
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: top),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

#if os(macOS)
typealias PlatformView = NSView
#else
typealias PlatformView = UIView
#endif
