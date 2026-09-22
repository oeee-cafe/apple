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

final class WebTabController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    let tab: WebTab
    let webView: WKWebView
    var onPageLoad: (() -> Void)?
    /// Whether the page is the painter, which has the whole screen (WebTabContent) and is
    /// not left without asking.
    @Published private(set) var isPainting = false
    /// Whether a page has finished loading, so the web view has a ground of its own.
    private(set) var hasLoaded = false
    /// Called when a page could not be loaded at all, as when the site cannot be reached.
    var onLoadFailed: ((Error) -> Void)?

    private static let logoutMessageName = "oeeeLogout"
    private static let presenceMessageName = "oeeePresence"

    /// What the page is, as the site tells the Steam app (`<meta name="oeee-presence">`,
    /// src/web/presence.rs in oeee-cafe/web). A page without it is browsing. Said by every
    /// page, and again by one brought back from the back-forward cache, so the last word is
    /// always the page on screen's.
    private static let presenceScript = """
    (function () {
      function tell() {
        var meta = document.querySelector('meta[name="oeee-presence"]');
        window.webkit.messageHandlers.\(presenceMessageName).postMessage(meta ? meta.content : null);
      }
      tell();
      window.addEventListener('pageshow', function (event) {
        if (event.persisted) tell();
      });
    })();
    """

    #if os(iOS)
    /// The painter zooms its canvas itself, but only for a pinch that starts on the canvas or
    /// the ground around it. One that starts anywhere else -- a room's chat, whose log
    /// scrolls -- reached WebKit and zoomed the whole page, panels and all. A drawing app
    /// does not do that, so its page is held at its own scale; WKWebView honours the limits
    /// that Safari overrides.
    private static let holdScaleScript = """
    (function () {
      var meta = document.querySelector('meta[name="viewport"]');
      if (!meta) {
        meta = document.createElement('meta');
        meta.name = 'viewport';
        document.head.appendChild(meta);
      }
      meta.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';
    })();
    """
    #endif

    /// The activities that are the painter; watching a replay is not.
    private static let paintingActivities: Set<String> = ["drawing", "relaying", "drawing-banner", "collaborating"]

    /// Whether the page would stop a browser from leaving it: its own `beforeunload`
    /// handlers, asked the way a browser asks them. WKWebView asks none of them, so a
    /// drawing would go without a word. The painter answers only for a drawing with
    /// something in it, and not while it is being saved.
    private static let wouldLoseWorkScript = """
    (function () {
      var event;
      try {
        event = document.createEvent("BeforeUnloadEvent");
        event.initEvent("beforeunload", false, true);
      } catch (_) {
        event = new Event("beforeunload", { cancelable: true });
      }
      window.dispatchEvent(event);
      return event.defaultPrevented ||
        (typeof event.returnValue === "string" && event.returnValue !== "");
    })()
    """

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
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        #if os(macOS)
        configuration.applicationNameForUserAgent = "OeeeCafeMac"
        SiteChrome.configure(configuration)
        #else
        // The site knows the app by this, and leaves search and scrolling to iOS
        // (`data-app="ios"`, theme_head.jinja in oeee-cafe/web).
        configuration.applicationNameForUserAgent = "OeeeCafeiOS"
        #endif
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.logoutScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.presenceScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

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
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.presenceMessageName)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        #if os(iOS)
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        #endif
        showPainting()

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

    #if os(iOS)
    private let refreshControl = UIRefreshControl()
    #endif

    @objc private func refresh() {
        webView.reload()
    }

    /// In the painter a swipe from the edge or down from the top is a stroke, not a way off
    /// the page.
    private func showPainting() {
        webView.allowsBackForwardNavigationGestures = !isPainting
        #if os(iOS)
        webView.scrollView.refreshControl = isPainting ? nil : refreshControl
        // Pages shorter than the screen can be pulled too.
        webView.scrollView.alwaysBounceVertical = !isPainting
        if isPainting {
            webView.evaluateJavaScript(Self.holdScaleScript)
        }
        #endif
    }

    private var isAskingToLeave = false

    /// Whether the page may be left: at once, unless it holds a drawing that has not been
    /// saved and the reader chooses to stay.
    func mayLeave() async -> Bool {
        guard !isAskingToLeave else { return false }
        guard (try? await webView.evaluateJavaScript(Self.wouldLoseWorkScript)) as? Bool == true else {
            return true
        }
        isAskingToLeave = true
        defer { isAskingToLeave = false }
        return await JavaScriptDialog.confirmLeaving(in: webView)
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
        if isMainFrame && isPainting {
            let leave = await mayLeave()
            if !leave { return .cancel }
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
        if message.name == Self.presenceMessageName {
            isPainting = (message.body as? String).map(Self.paintingActivities.contains) ?? false
            showPainting()
        } else if message.name == Self.logoutMessageName {
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

    /// Whether the reader means to leave a page that holds something unsaved. Staying is
    /// the default, so a reflexive Return keeps the drawing.
    static func confirmLeaving(in webView: WKWebView) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "leave.title".localized
        alert.informativeText = "leave.body".localized
        alert.addButton(withTitle: "leave.stay".localized)
        alert.addButton(withTitle: "leave.leave".localized)
        let response: NSApplication.ModalResponse
        if let window = webView.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertSecondButtonReturn
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

    /// Whether the reader means to leave a page that holds something unsaved.
    static func confirmLeaving(in webView: WKWebView) async -> Bool {
        guard var presenter = webView.window?.rootViewController else { return true }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: "leave.title".localized, message: "leave.body".localized, preferredStyle: .alert)
            let stay = UIAlertAction(title: "leave.stay".localized, style: .cancel) { _ in
                continuation.resume(returning: false)
            }
            alert.addAction(stay)
            alert.addAction(UIAlertAction(title: "leave.leave".localized, style: .destructive) { _ in
                continuation.resume(returning: true)
            })
            alert.preferredAction = stay
            presenter.present(alert, animated: true)
        }
    }
    #endif
}
