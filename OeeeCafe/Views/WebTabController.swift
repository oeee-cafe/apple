import SwiftUI
import Combine
import WebKit
#if os(iOS)
import UIKit
#endif

/// The app's one web view, and what the app knows of the page in it.
///
/// Split by what each part answers to: this file is the page's state and what the site says
/// about it (SiteBridge); WebTabController+Navigation.swift is where links may go;
/// WebTabController+UI.swift is WebKit asking for windows, dialogs and menus; Pencil.swift
/// is Apple Pencil in the painter.
final class WebTabController: NSObject, ObservableObject {
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
    /// APNs's token for this device, handed to the page as it arrives (`givePushToken`).
    private var pushToken: AnyCancellable?
    #if os(macOS)
    /// The site's ground, as the pages say it (SiteTheme).
    private var ground: AnyCancellable?
    #endif
    /// Asked once a leave is already being asked about, so a second does not stack on it.
    private var isAskingToLeave = false

    /// Who the page shown last said is signed in, or nil on a page that could not tell.
    /// A page already showing the new answer needs no reloading after a sign-in: it is the
    /// page that said so (`authenticationChanged`).
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
    /// The site's ground and grid behind the page, where the page does not reach.
    private var grid: PageGrid?
    #endif

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSession.shared.dataStore
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        #if os(macOS)
        // The site knows the Mac app by this, and marks its root `data-app="macos"`
        // and `data-form="desktop"` before the page paints (theme_head.jinja in
        // oeee-cafe/web): its toolbar is then the title bar, with room kept for the
        // traffic lights (ds.css). `store/apple` says the build sells through the App
        // Store -- the Mac app is sandboxed and sold through the Mac App Store under
        // the same bundle id, with the same pack in it -- so the page marks
        // `data-store="apple"` and draws the Supporter Pack's buttons (app_store.jinja).
        configuration.applicationNameForUserAgent = "OeeeCafe/macos store/apple"
        userScripts = SiteChrome.userScripts
        #else
        // The site knows the app by this, and marks its root `data-app="ios"`,
        // `data-form="handheld"` -- the page scrolls whole and a new one is pushed like
        // a screen -- and, for `store/apple`, `data-store="apple"`, so the Supporter
        // Pack's buttons are drawn (theme_head.jinja and app_store.jinja in
        // oeee-cafe/web).
        configuration.applicationNameForUserAgent = "OeeeCafe/ios store/apple"
        userScripts = []
        #endif

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        #if os(macOS)
        // A force click on a link opens WebKit's preview of the page, which is a browser's
        // gesture, not an application's.
        webView.allowsLinkPreview = false
        #else
        // Until the first page paints, and wherever a page does not reach -- above the home
        // indicator at its foot, past its ends when pulled -- the ground and its grid show through
        // (PageGrid) rather than a white web view.
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
        grid = PageGrid(under: webView.scrollView)
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
        #if os(macOS)
        // Under a page pulled past its ends, so a load does not flash either.
        ground = SiteTheme.shared.$colours.sink { [weak self] colours in
            self?.webView.underPageBackgroundColor = SiteTheme.ground(colours)
        }
        #endif
        showPageState()
        connectivity = Connectivity.shared.restored.sink { [weak self] in
            guard let self, self.isUnreachable else { return }
            self.retry()
        }
        // A token that arrives while a page is showing is handed to that page, rather than
        // waiting for the next one to say who is signed in: the first sign-in is the page
        // that asked for it, and may be the last page for a while. Only when the last page
        // believed said someone is signed in, which is the same word `pageSaid` goes by.
        pushToken = PushNotificationService.shared.$token.sink { [weak self] token in
            guard let self, self.hasLoaded, self.lastSignedIn == true, let token else { return }
            self.givePushToken(token)
        }
    }

    /// Shows the site's first page. Asked for rather than done on its own, so that whoever
    /// was signed in natively has been picked up before anything is fetched (WebSession).
    func start() {
        guard webView.url == nil else { return }
        load(Self.home)
    }

    /// The site's front page, where the app opens.
    private static var home: URL { URL(string: APIConfig.shared.baseURL + "/")! }

    func load(_ url: URL) {
        requestedURL = url
        webView.load(URLRequest(url: url))
    }

    /// Tries the page that could not be reached again.
    func retry() {
        isUnreachable = false
        load(requestedURL ?? webView.url ?? Self.home)
    }

    /// After signing in or out, the page showing was rendered for whoever was signed in
    /// before -- unless it is the page that said so, which is where signing in ends and
    /// which carries the notice that it worked. Reloading that one would throw the notice
    /// away for nothing.
    func authenticationChanged(signedIn: Bool) {
        guard lastSignedIn != signedIn else { return }
        webView.reload()
    }

    /// Lets the web view go: nothing it registered outlives it.
    func tearDown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
        connectivity = nil
        pushToken = nil
        #if os(macOS)
        ground = nil
        #endif
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
        #if os(iOS)
        content.addUserScript(Scripts.atDocumentStart(Scripts.textScale(Self.textScale)))
        #endif
    }

    #if os(iOS)
    /// The reader's text size (Dynamic Type), as a multiple of the system's default body
    /// size, for the site's type scale to follow (--oeee-text-scale, ds.css in
    /// oeee-cafe/web). Said as it is: the site keeps it within what its layouts were drawn
    /// for, so the largest accessibility sizes stop at twice the default there.
    private static var textScale: Double {
        let traits = UITraitCollection(preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory)
        let body = UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits)
        return body / 17
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
            SiteTheme.shared.paint(ground: theme.ground, grid: theme.grid)
            SiteTheme.shared.choose(theme.choice, in: webView.window)
        case .words(let words):
            SiteWords.current = words
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
        case .prices(let products):
            Task { await SupporterPack.prices(of: products, in: webView) }
        case .purchase(let product):
            Task { await SupporterPack.buy(product, in: webView) }
        case .restore:
            Task { await SupporterPack.restore(in: webView) }
        case .signIn(let provider, let nonce):
            Task { await SignIn.sheet(provider, nonce: nonce, in: webView) }
        case .window(let action):
            #if os(macOS)
            SiteChrome.windowAsked(action, of: webView.window)
            #else
            _ = action
            #endif
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
            if signedIn, let token = PushNotificationService.shared.token {
                givePushToken(token)
            }
        }
    }

    /// Hands the page this device's push token to register for whoever is signed in on it
    /// (`pushToken`, app_bridge.jinja in oeee-cafe/web). Every page that says someone is
    /// signed in is handed it, since the page is what knows whether the token is registered
    /// for them yet; one handed a token it already registered does nothing. Not on a page
    /// the back-forward cache kept, whose word on who is signed in is not yet believed
    /// (`restored`).
    private func givePushToken(_ token: String) {
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "window.oeeeApp && window.oeeeApp.pushToken && window.oeeeApp.pushToken(token);",
                arguments: ["token": token],
                in: nil,
                contentWorld: .page
            )
        }
    }

    /// In the painter a swipe from the edge or down from the top is a stroke, not a way off
    /// the page; and a page the site says may not be reloaded is not pulled down to reload.
    private func showPageState() {
        webView.allowsBackForwardNavigationGestures = !isPainting
        #if os(iOS)
        webView.scrollView.refreshControl = isRefreshable && !isPainting ? refreshControl : nil
        // Pages shorter than the screen can be pulled too.
        webView.scrollView.alwaysBounceVertical = !isPainting
        // A page is laid out in what the scroll view leaves unobscured, and the scroll view
        // keeps the strip above the home indicator to itself: a page that ends at the
        // screen's bottom edge is read past it, and a list's last row is not under the bar
        // the finger swipes up from. The painter is not read but filled, and it is given
        // the whole screen already -- no status bar (WebTabContent) -- so that
        // strip is the one place left where the screen is not the painter's. Nothing paints
        // it: the web view draws no ground of its own, so what was there stays there, which
        // is the page the painter was opened from.
        webView.scrollView.contentInsetAdjustmentBehavior = isPainting ? .never : .automatic
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
        let wouldLose = try? await webView.evaluateJavaScript(Scripts.wouldLoseWork, in: nil, contentWorld: .page)
        guard wouldLose as? Bool == true else {
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
        isMissingPage = true
        missingPageShown?.cancel()
        missingPageShown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.isMissingPage = false
        }
    }
}
