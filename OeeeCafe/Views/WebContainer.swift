import SwiftUI
import Combine
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shows the web view, in a container that lays it out.
#if os(macOS)
struct WebContainer: NSViewRepresentable {
    let controller: WebController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        Self.attach(controller.webView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {}
}
#else
/// The container fills the screen, but the web view stops at the status bar: a page pulled
/// down to refresh moves below it, with the spinner between, rather than under the Dynamic
/// Island. Behind the status bar is the toolbar's ground, as the pages say it
/// (`--ds-toolbar`, SiteTheme), which is what the top of every page is, so at rest the strip
/// and the toolbar read as one bar.
struct WebContainer: UIViewRepresentable {
    let controller: WebController

    func makeUIView(context: Context) -> Container { Container(webView: controller.webView) }

    func updateUIView(_ container: Container, context: Context) {}

    final class Container: UIView {
        private var ground: AnyCancellable?

        init(webView: WKWebView) {
            super.init(frame: .zero)
            // The web view draws no ground of its own (WebController), so this is what
            // shows behind the status bar, in whichever of the two the site's theme put the
            // window in (SiteTheme). Not the web view's `underPageBackgroundColor`: a web
            // view that draws no background has none to give -- it is transparent, and
            // stays so -- so asking it left the strip behind the clock black. The toolbar's
            // ground rather than the page's: the strip is the toolbar's top, and a toolbar
            // of its own colour under a strip of the page's showed a seam across the screen.
            ground = SiteTheme.shared.$pageGround
                .combineLatest(SiteTheme.shared.$pageToolbar)
                .sink { [weak self] ground, toolbar in
                    self?.backgroundColor = SiteTheme.toolbar(toolbar, ground: ground)
                }
            WebContainer.attach(webView, to: self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
#endif

extension WebContainer {
    static func attach(_ webView: WKWebView, to container: PlatformView) {
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
