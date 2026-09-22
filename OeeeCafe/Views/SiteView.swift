// The Mac app: one window onto the site, as oeee-cafe/desktop is on Steam.
//
// The site's toolbar is the window's title bar. The window's own title bar steps aside
// (transparent, its traffic lights moved into the toolbar at its left), and the site is told
// it is in the Mac app by `data-desktop="macos"` on its root element, which is what its
// styles for the desktop app key on. Where an iPhone has a tab bar, the Mac has the site's
// toolbar and a menu bar whose commands ask the page (`window.oeeeCommand`).
#if os(macOS)
import SwiftUI
import Combine
import WebKit
import AppKit

/// The one web view, and what the window and the menu bar ask of it.
final class Site: ObservableObject {
    static let shared = Site()

    enum State {
        case connecting
        case shown
        case unreachable
    }

    @Published private(set) var state: State = .connecting
    private(set) var controller: WebTabController?

    private init() {}

    /// Makes the web view once whoever is signed in on the web views has been picked up.
    func start() {
        guard controller == nil else { return }
        let controller = WebTabController(tab: .home)
        controller.onPageLoad = { [weak self] in self?.state = .shown }
        controller.onLoadFailed = { [weak self] error in
            guard let self, self.state != .shown, Self.isUnreachable(error) else { return }
            self.state = .unreachable
        }
        self.controller = controller
    }

    func retry() {
        state = .connecting
        controller?.load(WebTab.home.rootURL)
    }

    func load(_ url: URL) {
        controller?.load(url)
    }

    private static func isUnreachable(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code != NSURLErrorCancelled
    }

    // MARK: - Commands

    /// Where a command goes when the page has no toolbar to ask. Commands that are not a
    /// place do nothing there.
    private static let fallbacks: [String: String] = [
        "recent": "/", "about": "/", "following": "/home", "communities": "/communities",
        "together": "/collaborate", "hashtags": "/hashtags", "search": "/search",
        "notifications": "/notifications", "drafts": "/posts/drafts", "account": "/account",
    ]

    /// Asks the page to carry out one of the site's commands. Going somewhere is the page's
    /// own navigation, so a page holding an unsaved drawing still asks before it is left.
    func command(_ name: String) {
        var fallback = ""
        if let path = Self.fallbacks[name], let url = URL(string: APIConfig.shared.baseURL + path) {
            fallback = "location.href = \(Self.literal(url.absoluteString));"
        }
        evaluate("if (!(window.oeeeCommand && window.oeeeCommand(\(Self.literal(name))))) { \(fallback) }")
    }

    func back() { evaluate("history.back();") }
    func forward() { evaluate("history.forward();") }
    /// A plain reload, so a page holding a drawing asks first.
    func reload() { evaluate("location.reload();") }

    private func evaluate(_ script: String) {
        controller?.webView.evaluateJavaScript(script)
    }

    private static func literal(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Leaving

    /// Whether the app may quit: at once, unless the page holds something unsaved and the
    /// player chooses to stay.
    func mayLeave() async -> Bool {
        await controller?.mayLeave() ?? true
    }

    /// Closing the window is quitting: there is one window, and the page is asked first
    /// either way (AppDelegate's `applicationShouldTerminate`).
    @objc func closeWindow(_ sender: Any?) {
        NSApp.terminate(sender)
    }
}

/// The window: the site, with NEO's ground under it while it arrives.
struct SiteView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var site = Site.shared
    @StateObject private var navigationCoordinator = NavigationCoordinator.shared

    var body: some View {
        ZStack {
            Color(nsColor: SiteChrome.ground)
            if let controller = site.controller {
                WebTabView(controller: controller)
                    .opacity(site.state == .shown ? 1 : 0)
            }
            switch site.state {
            case .connecting:
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("site.connecting".localized)
            case .unreachable:
                VStack(spacing: 8) {
                    Text("site.unreachable_title".localized)
                        .font(.headline)
                    Text("site.unreachable_body".localized)
                        .foregroundStyle(.secondary)
                    Button("site.retry".localized) { site.retry() }
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 8)
                }
                .multilineTextAlignment(.center)
                .padding()
            case .shown:
                EmptyView()
            }
        }
        .ignoresSafeArea()
        .background(SiteWindowSetup())
        .frame(minWidth: 800, minHeight: 600)
        .task {
            // Picks up whoever is signed in on the web views before showing the site.
            await WebSession.shared.start()
            site.start()
            await authenticationChanged(authService.isAuthenticated)
            openPendingNavigation()
        }
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            Task { await authenticationChanged(isAuthenticated) }
        }
        .onChange(of: navigationCoordinator.pendingNavigation) { _, _ in
            openPendingNavigation()
        }
    }

    private func authenticationChanged(_ isAuthenticated: Bool) async {
        if isAuthenticated {
            // Registers this Mac's push token for the signed-in user (asking for
            // permission the first time).
            await PushNotificationService.shared.requestPermissionsAndRegister()
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
    }

    private func openPendingNavigation() {
        guard site.controller != nil, let pending = navigationCoordinator.pendingNavigation else { return }
        navigationCoordinator.clearPendingNavigation()
        if let url = pending.url {
            site.load(url)
        }
    }
}

// MARK: - The window

/// Makes the window's title bar step aside for the site's toolbar, and keeps the traffic
/// lights in it.
private struct SiteWindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowObserver() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowObserver: NSView {
        private var observations: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.forEach(NotificationCenter.default.removeObserver)
            observations = []
            guard let window else { return }

            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = SiteChrome.ground
            if let close = window.standardWindowButton(.closeButton) {
                close.target = Site.shared
                close.action = #selector(Site.closeWindow(_:))
            }

            // AppKit puts the buttons back wherever it lays out the title bar again.
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            observations = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window { SiteChrome.placeTrafficLights(in: window) }
                    }
                }
            }
            SiteChrome.placeTrafficLights(in: window)
        }
    }
}

/// What the site is told, and what it may ask of the window.
enum SiteChrome {
    /// NEO's ground, lavender by day and night blue by night (the asset catalog's Ground),
    /// under the page so a load does not flash.
    static let ground = NSColor(named: "Ground")!

    /// Where the traffic lights sit: their left edge, and how far down the title bar reaches
    /// so their centre meets the middle of the site's 52pt toolbar. oeee-cafe/desktop's
    /// measure.
    private static let trafficLightsX: CGFloat = 20
    private static let trafficLightsY: CGFloat = 28.5

    static func placeTrafficLights(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview?.superview else { return }
        let height = close.frame.height + trafficLightsY
        var frame = container.frame
        frame.size.height = height
        frame.origin.y = window.frame.height - height
        container.frame = frame
        let spacing = miniaturize.frame.minX - close.frame.minX
        for (index, button) in [close, miniaturize, zoom].enumerated() {
            button.setFrameOrigin(NSPoint(x: trafficLightsX + CGFloat(index) * spacing, y: button.frame.minY))
        }
    }

    private static let messageName = "oeeeWindow"

    /// Runs at the start of every page: tells the site where it is, makes room for the
    /// traffic lights, lets the toolbar's empty space drag the window, and reports the
    /// toolbar's unread count for the Dock. htmx replaces the body on boosted navigation,
    /// so the count is read again whenever the document changes.
    private static let script = """
    (function () {
      var root = document.documentElement;
      root.setAttribute("data-desktop", "macos");
      var style = document.createElement("style");
      style.textContent = 'html[data-desktop="macos"] .nav-bar #menubar { padding-left: 96px; }';
      (document.head || root).appendChild(style);
      function post(message) {
        window.webkit.messageHandlers.\(messageName).postMessage(message);
      }
      var unread = null;
      function reportUnread() {
        var bar = document.querySelector(".nav-bar");
        if (!bar) return;
        var badge = bar.querySelector("#nav-notifications .toolbar-badge");
        var count = badge ? parseInt(badge.textContent, 10) || 0 : 0;
        if (count === unread) return;
        unread = count;
        post({ unread: count });
      }
      document.addEventListener("DOMContentLoaded", reportUnread);
      new MutationObserver(reportUnread).observe(root, { childList: true, subtree: true });
      // The toolbar is the title bar: a press on its empty space moves the window, and a
      // double click zooms it. Its links, buttons and fields stay the page's.
      window.addEventListener("mousedown", function (event) {
        if (event.button !== 0 || event.defaultPrevented) return;
        var target = event.target;
        if (!target || !target.closest || !target.closest(".nav-bar")) return;
        if (target.closest("a, button, input, select, textarea, label, summary, details, [role], [contenteditable], [tabindex], [hx-get], [hx-post]")) return;
        event.preventDefault();
        post({ window: event.detail === 2 ? "zoom" : "drag" });
      });
    })();
    """

    /// The browser's own right-click menu -- Back, Reload, Open in New Window -- is the
    /// plainest sign that a window is a browser, so it is kept to text fields, a selection
    /// and images. Anywhere else a right click does nothing, unless the page has its own
    /// use for it, as the painter does.
    private static let quietContextMenu = """
    window.addEventListener("contextmenu", function (event) {
      if (event.defaultPrevented) return;
      var target = event.target;
      if (target && target.closest) {
        if (target.closest("input, textarea, select, [contenteditable]")) return;
        if (target.closest("img")) return;
      }
      if (window.getSelection && String(window.getSelection()) !== "") return;
      event.preventDefault();
    });
    """

    static func configure(_ configuration: WKWebViewConfiguration) {
        let content = configuration.userContentController
        for source in [script, quietContextMenu] {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        content.add(MessageHandler(), contentWorld: .page, name: messageName)
    }

    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let unread = body["unread"] as? Int {
                NSApp.dockTile.badgeLabel = unread > 0 ? String(unread) : nil
            }
            guard let window = message.webView?.window else { return }
            switch body["window"] as? String {
            case "drag":
                // The press has gone to the page and back; drag if the button is still down.
                guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
                let event = NSApp.currentEvent.flatMap { [.leftMouseDown, .leftMouseDragged].contains($0.type) ? $0 : nil }
                    ?? NSEvent.mouseEvent(
                        with: .leftMouseDown, location: window.mouseLocationOutsideOfEventStream,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1)
                if let event {
                    window.performDrag(with: event)
                }
            case "zoom":
                // What a double click on a title bar does, as set in System Settings.
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            default:
                break
            }
        }
    }
}

// MARK: - The menu bar

/// Every command the site offers, with the key an application would give it. The rest of
/// the menu bar -- Edit's cut and paste, which WebKit takes from the menu, Window, Hide and
/// Quit -- is the system's own.
struct SiteCommands: Commands {
    private let site = Site.shared

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("menu.about".localized) { site.command("about") }
        }
        CommandGroup(replacing: .appSettings) {
            Button("menu.settings".localized) { site.command("account") }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("menu.new_drawing".localized) { site.command("new-drawing") }
                .keyboardShortcut("n")
        }
        CommandGroup(replacing: .saveItem) {
            Button("menu.close_window".localized) { site.closeWindow(nil) }
                .keyboardShortcut("w")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            // The site's search, where an application keeps Find: the web view has no find
            // bar of its own, so the key is free.
            Button("menu.search".localized) { site.command("search") }
                .keyboardShortcut("f")
        }
        CommandGroup(before: .toolbar) {
            Button("menu.recent".localized) { site.command("recent") }
                .keyboardShortcut("1")
            Button("menu.following".localized) { site.command("following") }
                .keyboardShortcut("2")
            Button("menu.communities".localized) { site.command("communities") }
                .keyboardShortcut("3")
            Button("menu.together".localized) { site.command("together") }
                .keyboardShortcut("4")
            Button("menu.hashtags".localized) { site.command("hashtags") }
                .keyboardShortcut("5")
            Divider()
            Button("menu.notifications".localized) { site.command("notifications") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("menu.drafts".localized) { site.command("drafts") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("menu.profile".localized) { site.command("profile") }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("menu.back".localized) { site.back() }
                .keyboardShortcut("[")
            Button("menu.forward".localized) { site.forward() }
                .keyboardShortcut("]")
            Button("menu.reload".localized) { site.reload() }
                .keyboardShortcut("r")
            Divider()
            Menu("menu.theme".localized) {
                Button("menu.theme_light".localized) { site.command("theme-light") }
                Button("menu.theme_dark".localized) { site.command("theme-dark") }
                Button("menu.theme_system".localized) { site.command("theme-system") }
            }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("menu.shortcuts".localized) { site.command("shortcuts") }
                .keyboardShortcut("/")
        }
    }
}
#endif
