import SwiftUI
import Combine
import WebKit

/// A tab of the native tab bar, each showing its own page of the site.
enum WebTab: String, CaseIterable {
    case home
    case communities
    case collaborate
    case drafts
    case notifications
    case login
    case search

    var path: String {
        switch self {
        case .home: return "/"
        case .communities: return "/communities"
        case .collaborate: return "/collaborate"
        case .drafts: return "/posts/drafts"
        case .notifications: return "/notifications"
        case .login: return "/login"
        case .search: return "/search"
        }
    }

    var title: String {
        switch self {
        case .home: return "tab.home".localized
        case .communities: return "tab.communities".localized
        case .collaborate: return "tab.collaborate".localized
        case .drafts: return "tab.drafts".localized
        case .notifications: return "tab.notifications".localized
        case .login: return "tab.login".localized
        case .search: return "tab.search".localized
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .communities: return "person.3.fill"
        case .collaborate: return "person.2.crop.square.stack"
        case .drafts: return "doc.text"
        case .notifications: return "bell"
        case .login: return "person.circle"
        case .search: return "magnifyingglass"
        }
    }

    static func visible(isAuthenticated: Bool) -> [WebTab] {
        isAuthenticated
            ? [.home, .communities, .collaborate, .drafts, .notifications, .search]
            : [.home, .communities, .collaborate, .login, .search]
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

    init(tab: WebTab) {
        self.tab = tab

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSession.shared.dataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = "OeeeCafeiOS"
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.logoutScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif

        super.init()

        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.logoutMessageName)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

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
        let scrollView = webView.scrollView
        let top = -scrollView.adjustedContentInset.top
        if scrollView.contentOffset.y > top + 1 {
            scrollView.setContentOffset(CGPoint(x: 0, y: top), animated: true)
        } else if webView.url?.path != tab.path {
            load(tab.rootURL)
        }
    }

    func tearDown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
    }

    @objc private func refresh() {
        webView.reload()
    }

    private func endRefreshing() {
        webView.scrollView.refreshControl?.endRefreshing()
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
            await UIApplication.shared.open(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        endRefreshing()
        onPageLoad?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        endRefreshing()
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
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

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
                        .background(Color(uiColor: .systemBackground))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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
struct WebTabView: UIViewRepresentable {
    let controller: WebTabController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if controller.webView.superview !== container {
            attach(to: container)
        }
    }

    private func attach(to container: UIView) {
        let webView = controller.webView
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
