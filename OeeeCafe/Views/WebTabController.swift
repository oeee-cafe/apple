import SwiftUI
import Combine
import WebKit
#if os(iOS)
import UIKit
#endif

/// One tab's web view (the Mac's only one), and what the app knows of the page in it.
///
/// Split by what each part answers to: this file is the page's state and what the site says
/// about it (SiteBridge); WebTabController+Navigation.swift is where links may go;
/// WebTabController+UI.swift is WebKit asking for windows, dialogs and menus; Pencil.swift
/// is Apple Pencil in the painter.
final class WebTabController: NSObject, ObservableObject {
    let tab: WebTab
    let webView: WKWebView
    /// Whether the page is the painter, which has the whole screen (WebTabContent) and is
    /// not left without asking.
    @Published private(set) var isPainting = false
    /// Whether pulling the page down may reload it, as the page says.
    @Published private(set) var isRefreshable = true
    /// Whether a page has finished loading, so the web view has a ground of its own.
    @Published private(set) var hasLoaded = false
    /// Whether the site could not be reached with nothing yet to show (UnreachableView).
    @Published private(set) var isUnreachable = false
    /// Whether to say, for a moment, that a page could not be reached while another was
    /// showing, which stays (the notice in Unreachable.swift).
    @Published private(set) var isMissingPage = false
    private var missingPageShown: Task<Void, Never>?
    /// The page last asked for, to ask for again.
    var requestedURL: URL?
    private var connectivity: AnyCancellable?
    /// Asked once a leave is already being asked about, so a second does not stack on it.
    private var isAskingToLeave = false
    /// Who the page shown last said is signed in, or nil on a page that could not tell.
    /// A tab already showing the new answer needs no reloading after a sign-in: it is the
    /// page that said so (WebTabStore.authenticationChanged).
    private(set) var lastSignedIn: Bool?

    /// Whether the last page arrived by Back or Forward, and so may be the copy the
    /// back-forward cache kept (see `pageSaid`).
    var restored = RestoredPage.none

    /// The scripts this web view runs at the start of every page, apart from the text
    /// scale, which changes (`installUserScripts`).
    private let userScripts: [WKUserScript]

    #if os(iOS)
    let refreshControl = UIRefreshControl()
    /// The drawing a finger last landed on, as the page said (DrawingMenu).
    var pressedDrawing: DrawingMenu.Drawing?
    /// Apple Pencil's double-tap and squeeze, for the painter (Pencil.swift).
    lazy var pencil = UIPencilInteraction(delegate: self)
    private var observers: [NSObjectProtocol] = []
    #endif

    init(tab: WebTab) {
        self.tab = tab

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSession.shared.dataStore
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        #if os(macOS)
        // The site knows the Mac app by this (`data-mac-app`, theme_head.jinja in
        // oeee-cafe/web), and that it signs in with Apple and with Google itself
        // rather than by following those links, which would open them outside the
        // app and away from the session the answer belongs to.
        configuration.applicationNameForUserAgent = "OeeeCafeMac"
        userScripts = SiteChrome.userScripts
        SiteChrome.install(in: configuration.userContentController)
        #else
        // The site knows the app by this, and leaves search and scrolling to iOS
        // (`data-app="ios"`, theme_head.jinja in oeee-cafe/web) -- and signing in with
        // Apple and with Google, which the app does itself (AppleSignIn, GoogleSignIn).
        configuration.applicationNameForUserAgent = "OeeeCafeiOS"
        userScripts = []
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

        SiteBridge.install(in: configuration.userContentController) { [weak self] message in
            self?.hear(message)
        }
        installUserScripts()
        webView.navigationDelegate = self
        webView.uiDelegate = self

        #if os(iOS)
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        webView.addInteraction(pencil)
        observers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // "Only Draw with Apple Pencil" may have changed while the app was away.
                MainActor.assumeIsolated {
                    guard let self, self.isPainting else { return }
                    self.showPencilOnly()
                }
            },
            NotificationCenter.default.addObserver(
                forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.showTextScale() }
            },
        ]
        #endif
        showPageState()
        connectivity = Connectivity.shared.restored.sink { [weak self] in
            guard let self, self.isUnreachable else { return }
            self.retry()
        }

        // Search shows nothing until something is searched for.
        if tab != .search {
            load(tab.rootURL)
        }
    }

    func load(_ url: URL) {
        requestedURL = url
        webView.load(URLRequest(url: url))
    }

    /// Shows `url`, unless the page showing is already it: a tab stepped into keeps where
    /// the reader was in it.
    func show(_ url: URL) {
        guard !hasLoaded || webView.url != url else { return }
        load(url)
    }

    /// Tries the page that could not be reached again.
    func retry() {
        isUnreachable = false
        load(requestedURL ?? webView.url ?? tab.rootURL)
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
        Task {
            let scrolled = try? await webView.evaluateJavaScript(Scripts.scrollToTop) as? Bool
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

    /// Lets the tab go: nothing it registered outlives it.
    func tearDown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
        connectivity = nil
        missingPageShown?.cancel()
        #if os(iOS)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        #endif
    }

    // MARK: - Scripts

    /// Puts this web view's scripts on every page from its start: its own, and the reader's
    /// text size. WebKit can take its scripts away only all at once, so they are put back
    /// all at once from this one list, rather than by sorting out which of the ones already
    /// there to keep.
    private func installUserScripts() {
        let content = webView.configuration.userContentController
        content.removeAllUserScripts()
        userScripts.forEach(content.addUserScript)
        content.addUserScript(Scripts.atDocumentStart(Scripts.markStore))
        #if os(iOS)
        content.addUserScript(Scripts.atDocumentStart(Scripts.textScale(Self.textScale)))
        #endif
    }

    #if os(iOS)
    /// The reader's text size (Dynamic Type), as a multiple of the system's default body
    /// size, for the site's type scale to follow (--oeee-text-scale, ds.css in
    /// oeee-cafe/web). Kept within what its layouts were drawn for: the largest
    /// accessibility sizes stop at twice the default.
    private static var textScale: Double {
        let traits = UITraitCollection(preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory)
        let body = UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits)
        return min(max(body / 17, 0.8), 2)
    }

    /// Puts the reader's new text size on the pages to come, and on the page showing now.
    private func showTextScale() {
        installUserScripts()
        webView.evaluateJavaScript(Scripts.textScale(Self.textScale))
    }

    /// "Only Draw with Apple Pencil": fingers pan and pinch from the first stroke, rather
    /// than from the first time the painter sees a pen.
    func showPencilOnly() {
        guard UIPencilInteraction.prefersPencilOnlyDrawing else { return }
        webView.evaluateJavaScript(Scripts.preferPen)
    }
    #endif

    @objc private func refresh() {
        webView.reload()
    }

    // MARK: - What the site says

    /// Whether a page arrived by Back or Forward. A page the back-forward cache kept was
    /// rendered for whoever was signed in when it was left, and says so again as it comes
    /// back; so what it says about signing in counts only once the reader has gone on from
    /// it to another page.
    enum RestoredPage {
        case none
        /// Arriving: the next page to speak is the restored one.
        case arriving
        case at(path: String)
    }

    private func hear(_ message: SiteMessage) {
        switch message {
        case .page(let page):
            pageSaid(page)
        case .unread(let count):
            UnreadCount.shared.set(count)
        case .theme(let theme):
            SiteTheme.shared.choose(theme.choice, in: webView.window)
        case .haptic(let name):
            #if os(iOS)
            Haptics.play(name)
            #else
            _ = name
            #endif
        case .pressed(let drawing):
            #if os(iOS)
            pressedDrawing = drawing.flatMap { DrawingMenu.drawing(from: $0, referrer: webView.url) }
            #else
            _ = drawing
            #endif
        case .painterReady:
            #if os(iOS)
            showPencilOnly()
            #endif
        case .prices(let store, let products):
            guard store == "apple" else { break }
            Task { await SupporterPack.prices(of: products, in: webView) }
        case .purchase(let purchase):
            guard purchase.store == "apple" else { break }
            Task { await SupporterPack.buy(purchase.product, in: webView) }
        case .restore:
            Task { await SupporterPack.restore(in: webView) }
        }
    }

    private func pageSaid(_ page: SiteMessage.Page) {
        if page.painting != isPainting || page.refreshable != isRefreshable {
            isPainting = page.painting
            isRefreshable = page.refreshable
            showPageState()
        }

        var trusted = true
        switch restored {
        case .none:
            break
        case .arriving:
            restored = .at(path: page.path)
            trusted = false
        case .at(let path):
            if path == page.path {
                trusted = false
            } else {
                restored = .none
            }
        }
        if trusted, let signedIn = page.signedIn {
            lastSignedIn = signedIn
            AuthService.shared.pageSaid(signedIn: signedIn)
        }

        #if os(iOS)
        showSection(page.path)
        #endif
    }

    #if os(iOS)
    /// A tab's own page arriving in another tab -- the site's toolbar has the sections of
    /// the tab bar in it, and swaps one in wherever it is tapped -- moves the reader to the
    /// tab it belongs to, and this tab back to the page it was showing. The two ways to a
    /// section, the tab bar and the toolbar, then never say different things about where
    /// the reader is. (The Mac has no tabs: there the toolbar is the only way.)
    private func showSection(_ path: String) {
        guard let owner = WebTab.owning(path: path), owner != tab,
              WebTab.visible(isAuthenticated: AuthService.shared.isAuthenticated).contains(owner)
        else { return }
        Logger.debug("WebTab \(tab.rawValue): \(path) is the \(owner.rawValue) tab's own page", category: Logger.app)
        NavigationCoordinator.shared.show(section: owner)
        // The toolbar's link was boosted: the section is in this web view already, and its
        // history entry with it, so the way back to the page under it is the way back.
        if webView.canGoBack {
            webView.goBack()
        } else {
            load(tab.rootURL)
        }
    }
    #endif

    /// In the painter a swipe from the edge or down from the top is a stroke, not a way off
    /// the page; and a page the site says may not be reloaded is not pulled down to reload.
    private func showPageState() {
        webView.allowsBackForwardNavigationGestures = !isPainting
        #if os(iOS)
        webView.scrollView.refreshControl = isRefreshable && !isPainting ? refreshControl : nil
        // Pages shorter than the screen can be pulled too.
        webView.scrollView.alwaysBounceVertical = !isPainting
        pencil.isEnabled = isPainting
        if isPainting {
            webView.evaluateJavaScript(Scripts.holdScale)
        }
        #endif
    }

    // MARK: - Leaving

    /// Whether the page may be left: at once, unless it holds a drawing that has not been
    /// saved and the reader chooses to stay.
    func mayLeave() async -> Bool {
        guard !isAskingToLeave else { return false }
        guard (try? await webView.evaluateJavaScript(Scripts.wouldLoseWork)) as? Bool == true else {
            return true
        }
        isAskingToLeave = true
        defer { isAskingToLeave = false }
        return await JavaScriptDialog.confirmLeaving(in: webView)
    }

    // MARK: - Loading

    func pageFinished() {
        hasLoaded = true
        isUnreachable = false
        endRefreshing()
    }

    func endRefreshing() {
        #if os(iOS)
        webView.scrollView.refreshControl?.endRefreshing()
        #endif
    }

    /// A page that could not be reached: the page that was left stays, with a moment's
    /// notice, or with nothing yet to show, words for it (Unreachable.swift).
    func pageUnreachable() {
        guard hasLoaded else {
            isUnreachable = true
            return
        }
        // The skeleton the site put up for the next page (toolbar.jinja) comes down at
        // once rather than after its own timeout.
        webView.evaluateJavaScript(Scripts.restoreContent)
        isMissingPage = true
        missingPageShown?.cancel()
        missingPageShown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.isMissingPage = false
        }
    }
}
