import SwiftUI
import Combine
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A tab of the native tab bar, each showing its own page of the site.
enum WebTab: String, CaseIterable {
    case home
    case communities
    case notifications
    case login
    case search

    var path: String {
        switch self {
        case .home: return "/"
        case .communities: return "/communities"
        case .notifications: return "/notifications"
        case .login: return "/login"
        case .search: return "/search"
        }
    }

    var title: String {
        switch self {
        case .home: return "tab.home".localized
        case .communities: return "tab.communities".localized
        case .notifications: return "tab.notifications".localized
        case .login: return "tab.login".localized
        case .search: return "tab.search".localized
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .communities: return "person.3.fill"
        case .notifications: return "bell"
        case .login: return "person.circle"
        case .search: return "magnifyingglass"
        }
    }

    static func visible(isAuthenticated: Bool) -> [WebTab] {
        isAuthenticated
            ? [.home, .communities, .notifications, .search]
            : [.home, .communities, .login, .search]
    }

    var rootURL: URL {
        URL(string: APIConfig.shared.baseURL + path)!
    }
}

/// Owns one long-lived web view per tab, so each tab keeps its own history and scroll position.
final class WebTabStore: ObservableObject {
    private var controllers: [WebTab: WebTabController] = [:]

    /// Called whenever any tab finishes loading a page.
    var onPageLoad: (() -> Void)?

    func controller(for tab: WebTab) -> WebTabController {
        if let controller = controllers[tab] {
            return controller
        }
        let controller = WebTabController(tab: tab)
        controller.onPageLoad = { [weak self] in self?.onPageLoad?() }
        controllers[tab] = controller
        return controller
    }

    /// After signing in or out, every page shown so far was rendered for the other user.
    /// Drops the tabs that are no longer shown and reloads the rest.
    func authenticationChanged(visibleTabs: [WebTab]) {
        for tab in controllers.keys where !visibleTabs.contains(tab) {
            controllers.removeValue(forKey: tab)?.tearDown()
        }
        for controller in controllers.values {
            controller.webView.reload()
        }
    }
}

final class WebTabController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    let tab: WebTab
    let webView: WKWebView
    var onPageLoad: (() -> Void)?
    /// Whether a page has finished loading, so the web view has a ground of its own.
    private(set) var hasLoaded = false
    /// Called when a page could not be loaded at all, as when the site cannot be reached.
    var onLoadFailed: ((Error) -> Void)?

    private static let logoutMessageName = "oeeeLogout"

    /// Holds a sign-out form's submission until the device's push token is unregistered,
    /// which needs the session the sign-out is about to end.
    private static let logoutScript = """
    window.addEventListener('submit', function (event) {
      var form = event.target;
      if (!(form instanceof HTMLFormElement) || form.dataset.oeeeDeviceReleased) return;
      var action = new URL(form.getAttribute('action') || '', location.href);
      if (action.origin !== location.origin || action.pathname !== '/logout') return;
      event.preventDefault();
      event.stopImmediatePropagation();
      var submitter = event.submitter;
      window.webkit.messageHandlers.\(logoutMessageName).postMessage(null)
        .catch(function () {})
        .then(function () {
          form.dataset.oeeeDeviceReleased = '1';
          if (submitter) { form.requestSubmit(submitter); } else { form.requestSubmit(); }
        });
    }, true);
    """

    #if os(iOS)
    /// Tells the site it is in the iOS app, as the Mac app tells it with `data-desktop`: the
    /// site then leaves scrolling to iOS -- the page scrolls and bounces at every width, so
    /// the web view's own scroll view gives pull to refresh, a tap on the status bar to go
    /// back to the top, and iOS's scroll indicator.
    private static let mobileScript = """
    document.documentElement.setAttribute("data-mobile", "ios");
    """
    #endif

    init(tab: WebTab) {
        self.tab = tab

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSession.shared.dataStore
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        #if os(macOS)
        configuration.applicationNameForUserAgent = "OeeeCafeMac"
        SiteChrome.configure(configuration)
        #else
        configuration.applicationNameForUserAgent = "OeeeCafeiOS"
        #endif
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.logoutScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        #if os(iOS)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.mobileScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        #endif

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        #if os(macOS)
        // A force click on a link opens WebKit's preview of the page, which is a browser's
        // gesture, not an application's.
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = SiteChrome.ground
        #else
        // Until the first page paints, the ground shows through (WebTabView's container)
        // rather than a white web view.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
        #if DEBUG
        webView.isInspectable = true
        #endif

        super.init()

        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.logoutMessageName)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        #if os(iOS)
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
        // Pages shorter than the screen can be pulled too.
        webView.scrollView.alwaysBounceVertical = true
        #endif

        // Search shows nothing until something is searched for.
        if tab != .search {
            webView.load(URLRequest(url: tab.rootURL))
        }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Shows the site's results for `query` (`/search?q=`).
    func search(_ query: String) {
        var components = URLComponents(url: tab.rootURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = components?.url {
            load(url)
        }
    }

    /// Tapping the selected tab again: scroll to the top, or go back to the tab's own page.
    func reselect() {
        #if os(macOS)
        // There is no scroll view to ask on macOS. On wide windows the site scrolls `main`
        // rather than the page, so whichever of the two is scrolled goes back to the top.
        Task {
            let scrolled = try? await webView.evaluateJavaScript("""
            (function () {
              var scrolled = [document.scrollingElement, document.querySelector('main.ds-content')]
                .filter(function (element) { return element && element.scrollTop > 1; });
              scrolled.forEach(function (element) { element.scrollTo({ top: 0, behavior: 'smooth' }); });
              return scrolled.length > 0;
            })();
            """) as? Bool
            if scrolled != true && webView.url?.path != tab.path {
                load(tab.rootURL)
            }
        }
        #else
        let scrollView = webView.scrollView
        let top = -scrollView.adjustedContentInset.top
        if scrollView.contentOffset.y > top + 1 {
            scrollView.setContentOffset(CGPoint(x: 0, y: top), animated: true)
        } else if webView.url?.path != tab.path {
            load(tab.rootURL)
        }
        #endif
    }

    func tearDown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
    }

    @objc private func refresh() {
        webView.reload()
    }

    private func endRefreshing() {
        #if os(iOS)
        webView.scrollView.refreshControl?.endRefreshing()
        #endif
    }

    private func openOutside(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    private func isSiteURL(_ url: URL) -> Bool {
        url.host == tab.rootURL.host
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let isWebURL = url.scheme == "http" || url.scheme == "https"

        // Other sites (and mailto: etc.) open outside the app; embeds in frames load as usual.
        if isMainFrame && !(isWebURL && isSiteURL(url)) && url.scheme != "about" && url.scheme != "blob" && url.scheme != "data" {
            openOutside(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoaded = true
        endRefreshing()
        onPageLoad?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        endRefreshing()
        onLoadFailed?(error)
        Logger.warning("WebTab \(tab.rawValue): Failed to load - \(error.localizedDescription)", category: Logger.network)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - WKUIDelegate

    /// Links that ask for a new window open in this tab, or outside the app for other sites.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isSiteURL(url) {
                webView.load(navigationAction.request)
            } else {
                openOutside(url)
            }
        }
        return nil
    }

    // WKWebView shows none of alert(), confirm() or prompt() by itself: without these,
    // alert() does nothing and confirm() answers "cancel", which htmx takes as "no".

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        _ = await JavaScriptDialog.present(message: message, in: webView, kind: .alert)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await JavaScriptDialog.present(message: message, in: webView, kind: .confirm) != nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        await JavaScriptDialog.present(message: prompt, in: webView, kind: .prompt(defaultText ?? ""))
    }

    #if os(macOS)
    /// `<input type="file">`: iOS shows its own picker, macOS asks the app.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        guard let window = webView.window else {
            return panel.runModal() == .OK ? panel.urls : nil
        }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }
    #endif

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        if message.name == Self.logoutMessageName {
            Logger.info("WebTab: Signing out, unregistering push device first", category: Logger.auth)
            await PushNotificationService.shared.deleteDevice()
        }
        return (nil, nil)
    }
}

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
                if !hasSearched {
                    ContentUnavailableView("tab.search".localized, systemImage: "magnifyingglass")
                        .background(.background)
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
/// Island. Behind the status bar is the page's own ground, so at rest the two read as one.
struct WebTabView: UIViewRepresentable {
    let controller: WebTabController

    func makeUIView(context: Context) -> UIView {
        let container = Container()
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if controller.webView.superview !== container {
            attach(to: container)
        }
    }

    final class Container: UIView {
        private var ground: NSKeyValueObservation?

        func show(_ controller: WebTabController) {
            let webView = controller.webView
            // NEO's ground until the page says what its own is.
            backgroundColor = controller.hasLoaded ? webView.underPageBackgroundColor : UIColor(named: "Ground")
            ground = webView.observe(\.underPageBackgroundColor) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.backgroundColor = webView.underPageBackgroundColor
                }
            }
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
        (container as? Container)?.show(controller)
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

/// A page's alert(), confirm() or prompt(), shown over the web view's window.
/// Answers nil when cancelled, otherwise the entered text ("" for alerts and confirms).
enum JavaScriptDialog {
    enum Kind {
        case alert
        case confirm
        case prompt(String)
    }

    #if os(macOS)
    static func present(message: String, in webView: WKWebView, kind: Kind) async -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "common.ok".localized)
        var field: NSTextField?
        switch kind {
        case .alert:
            break
        case .confirm:
            alert.addButton(withTitle: "common.cancel".localized)
        case .prompt(let defaultText):
            alert.addButton(withTitle: "common.cancel".localized)
            let textField = NSTextField(string: defaultText)
            textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = textField
            alert.window.initialFirstResponder = textField
            field = textField
        }
        let response: NSApplication.ModalResponse
        if let window = webView.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return field?.stringValue ?? ""
    }
    #else
    static func present(message: String, in webView: WKWebView, kind: Kind) async -> String? {
        guard var presenter = webView.window?.rootViewController else { return nil }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            switch kind {
            case .alert:
                break
            case .confirm:
                alert.addAction(UIAlertAction(title: "common.cancel".localized, style: .cancel) { _ in
                    continuation.resume(returning: nil)
                })
            case .prompt(let defaultText):
                alert.addTextField { $0.text = defaultText }
                alert.addAction(UIAlertAction(title: "common.cancel".localized, style: .cancel) { _ in
                    continuation.resume(returning: nil)
                })
            }
            alert.addAction(UIAlertAction(title: "common.ok".localized, style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text ?? "")
            })
            presenter.present(alert, animated: true)
        }
    }
    #endif
}
