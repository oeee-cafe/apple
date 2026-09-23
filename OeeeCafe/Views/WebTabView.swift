import SwiftUI
import Combine
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The search tab: the native search field, with the site's search page under it.
///
/// The field is the search role tab's own (ContentView), and iOS puts it where that
/// release keeps search: in place of the tab bar on iOS 26, in the navigation bar on
/// iOS 27. So the bar stays, empty as it looks on the tab that hides it; hidden, iOS 27
/// has nowhere to show the field, and the tab opens with nothing to type in. Stepping
/// into the tab hands the field the keyboard, rather than waiting to be tapped as well.
///
/// What the page under it shows before anything is searched for is the site's own search
/// page, which leaves its form out where a field like this one is above it (search.jinja
/// in oeee-cafe/web).
struct SearchTabView: View {
    @ObservedObject var controller: WebTabController
    /// Whether this is the tab showing, which is when the field takes the keyboard.
    let isSelected: Bool
    @State private var query = ""
    @FocusState private var isSearching: Bool

    var body: some View {
        NavigationStack {
            WebTabView(controller: controller)
                .ignoresSafeArea(.container)
                .unreachable(controller)
        }
        .searchable(text: $query)
        .searchFocused($isSearching)
        .onChange(of: isSelected, initial: true) { _, selected in
            guard selected else { return }
            // Asked for as the tab is being built, the focus has no field to land on yet:
            // the next turn of the run loop does.
            Task { @MainActor in
                isSearching = true
            }
        }
        .onSubmit(of: .search) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
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
        Self.attach(controller.webView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if controller.webView.superview !== container {
            Self.attach(controller.webView, to: container)
        }
    }
}
#else
/// The container fills the screen, but the web view stops at the status bar: a page pulled
/// down to refresh moves below it, with the spinner between, rather than under the Dynamic
/// Island. Behind the status bar is the site's ground, as the pages say it (`--ds-ground`,
/// SiteTheme), which is what the site lays its pages on, so at rest the two read as one.
struct WebTabView: UIViewRepresentable {
    let controller: WebTabController

    func makeUIView(context: Context) -> Container { Container(controller: controller) }

    func updateUIView(_ container: Container, context: Context) {
        container.takeWebView()
    }

    /// Every tab shows the same web view, and a view can only be in one place: the
    /// container the reader is looking at takes it, and takes it when it is put on screen
    /// rather than when SwiftUI happens to ask. A tab left behind is asked too -- it is
    /// still built, off screen -- and taking it back there is what left the tab stepped
    /// into with nothing in it.
    final class Container: UIView {
        private let controller: WebTabController
        private var ground: AnyCancellable?

        init(controller: WebTabController) {
            self.controller = controller
            super.init(frame: .zero)
            // The web view draws no ground of its own (WebTabController), so this is what
            // shows behind the status bar, in whichever of the two the site's theme put the
            // window in (SiteTheme). Not the web view's `underPageBackgroundColor`: a web
            // view that draws no background has none to give -- it is transparent, and
            // stays so -- so asking it left the strip behind the clock black.
            ground = SiteTheme.shared.$colours.sink { [weak self] colours in
                self?.backgroundColor = SiteTheme.ground(colours)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            takeWebView()
        }

        func takeWebView() {
            guard window != nil, controller.webView.superview !== self else { return }
            WebTabView.attach(controller.webView, to: self)
        }
    }
}
#endif

extension WebTabView {
    static func attach(_ webView: WKWebView, to container: PlatformView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        #if os(macOS)
        let top = container.topAnchor
        #else
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
