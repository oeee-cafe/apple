import SwiftUI
import Combine
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shows the web view. The web view outlives this view, so it is hosted in a container
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
/// The container fills the screen, but the web view stops at the status bar, so nothing of
/// the page is under the Dynamic Island. Behind the status bar is the site's ground, as the pages say it (`--ds-ground`,
/// SiteTheme), which is what the site lays its pages on, so at rest the two read as one.
struct WebTabView: UIViewRepresentable {
    let controller: WebTabController

    func makeUIView(context: Context) -> Container { Container(controller: controller) }

    func updateUIView(_ container: Container, context: Context) {
        container.takeWebView()
    }

    /// The web view outlives any one container, and a view can only be in one place: the
    /// container takes it when it is put on screen rather than when SwiftUI happens to ask.
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
