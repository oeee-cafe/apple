// The Mac app: one window onto the site, as oeee-cafe/desktop is on Steam.
//
// The site's toolbar is the window's title bar. The window's own title bar steps aside
// (transparent, its traffic lights moved into the toolbar at its left). The site knows it is
// in the Mac app by the web view's user agent (WebTabController) and marks its own root
// `data-app="macos"`, which is what its styles for the Mac key on, room for the traffic
// lights included. As on an iPhone, the site's toolbar is the way around, and the
// Mac adds a menu bar whose commands ask the page (`window.oeeeApp.command`).
#if os(macOS)
import SwiftUI
import Combine
import WebKit
import AppKit

/// The one web view, and what the window and the menu bar ask of it.
final class Site: ObservableObject {
    static let shared = Site()

    @Published private(set) var controller: WebTabController?

    private init() {}

    /// Makes the web view once whoever is signed in on the web views has been picked up.
    func start() {
        guard controller == nil else { return }
        let controller = WebTabController()
        controller.start()
        self.controller = controller
        listenForSideButtons()
        listenForFullScreenKey()
    }

    func load(_ url: URL) {
        controller?.load(url)
    }

    // MARK: - Commands

    /// Asks the page to carry out one of the site's commands. Going somewhere is the page's
    /// own navigation, so a page holding an unsaved drawing still asks before it is left.
    ///
    /// The site's toolbar is the one list of what each command does. On a page without it
    /// -- a replay -- a menu item does nothing; this used to load the command's page from a
    /// table of the site's routes kept here, a second copy of them to keep in step.
    func command(_ name: String) {
        evaluate(Scripts.siteCommand(name))
    }

    func back() { evaluate("history.back();") }
    func forward() { evaluate("history.forward();") }
    /// A plain reload, so a page holding a drawing asks first.
    func reload() { evaluate("location.reload();") }

    /// The two buttons under a mouse's thumb. WebKit hands them to the page as plain
    /// auxiliary clicks and goes nowhere itself -- a browser carries them in its own
    /// chrome -- so the app hears them here and asks for the same back and forward the
    /// menu bar does. The page never sees them: a press meant for the history is not a
    /// click on whatever it landed on.
    private var sideButtons: Any?

    private func listenForSideButtons() {
        guard sideButtons == nil else { return }
        sideButtons = NSEvent.addLocalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseUp, .otherMouseDragged]
        ) { event in
            // The press acts as it goes down, as it does in a browser; the release and
            // any drag between are swallowed with it.
            let ours = MainActor.assumeIsolated { () -> Bool in
                switch (event.buttonNumber, event.type) {
                case (Self.backButton, .otherMouseDown): Site.shared.back()
                case (Self.forwardButton, .otherMouseDown): Site.shared.forward()
                case (Self.backButton, _), (Self.forwardButton, _): break
                default: return false
                }
                return true
            }
            return ours ? nil : event
        }
    }

    /// ⌃⌘F, full screen's key before fn-F. The View menu's Enter Full Screen, which AppKit
    /// adds, answers only fn-F now, and a Mac user's hands still know the older key.
    private var fullScreenKey: Any?

    private func listenForFullScreenKey() {
        guard fullScreenKey == nil else { return }
        fullScreenKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard flags == [.command, .control],
                  event.charactersIgnoringModifiers?.lowercased() == "f"
            else { return event }
            let toggled = MainActor.assumeIsolated { () -> Bool in
                guard let window = event.window ?? NSApp.keyWindow else { return false }
                window.toggleFullScreen(nil)
                return true
            }
            return toggled ? nil : event
        }
    }

    /// AppKit numbers the buttons from the left one: back and forward are the fourth and
    /// the fifth.
    private static let backButton = 3
    private static let forwardButton = 4

    private func evaluate(_ script: String) {
        controller?.webView.evaluateJavaScript(script)
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

/// The window: the site, with the site's ground under it while it arrives.
struct SiteView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var site = Site.shared
    @StateObject private var navigationCoordinator = NavigationCoordinator.shared
    @ObservedObject private var theme = SiteTheme.shared

    var body: some View {
        ZStack {
            Color(nsColor: theme.ground)
            if let controller = site.controller {
                SitePage(controller: controller)
            } else {
                connecting
            }
        }
        .ignoresSafeArea()
        .background(SiteWindowSetup())
        .frame(minWidth: 800, minHeight: 600)
        .task {
            // Carries over a session signed in natively before showing the site.
            await WebSession.shared.start()
            site.start()
            // Before asking about notifications: a page waiting to be opened is what the
            // reader came for, and does not wait behind a permission they may sit on.
            openPendingNavigation()
            await authenticationChanged(authService.isAuthenticated)
        }
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            Task { await authenticationChanged(isAuthenticated) }
        }
        .onChange(of: navigationCoordinator.pendingNavigation) { _, _ in
            openPendingNavigation()
        }
        // A clicked oeee.cafe link handed over as a URL. The Mac hands over most of them
        // as an activity instead, which AppDelegate hears (`application(_:continue:)`).
        .onOpenURL { url in
            navigationCoordinator.open(url)
        }
    }

    private var connecting: some View {
        ProgressView()
            .controlSize(.large)
            .accessibilityLabel("site.connecting".localized)
    }

    private func authenticationChanged(_ isAuthenticated: Bool) async {
        if isAuthenticated {
            // Asks for this Mac's push token (and for permission, the first time), which
            // the pages then register for whoever is signed in.
            await PushNotificationService.shared.requestPermissionsAndRegister()
        } else {
            UnreadCount.shared.clear()
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

/// The page, once it has arrived; until then the site's ground and a spinner, or the words for
/// a site that could not be reached.
private struct SitePage: View {
    @ObservedObject var controller: WebTabController

    var body: some View {
        ZStack {
            WebTabView(controller: controller)
                .opacity(controller.hasLoaded ? 1 : 0)
                .unreachable(controller)
            if !controller.hasLoaded && !controller.isUnreachable {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("site.connecting".localized)
            }
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
        private var ground: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.forEach(NotificationCenter.default.removeObserver)
            observations = []
            ground = nil
            guard let window else { return }

            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // The site's ground, as the pages say it, behind the page while it arrives.
            ground = SiteTheme.shared.$colours.sink { [weak window] colours in
                window?.backgroundColor = SiteTheme.ground(colours)
            }
            SiteTheme.shared.apply(to: window)
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
            // Full screen moves the title bar into a strip of its own that comes down
            // with the menu bar, and AppKit lays it out there from the frames it finds:
            // left where they are, measured from the top of a whole window, the buttons
            // land outside the strip and are never seen. So they go back first.
            observations.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
                ) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window { SiteChrome.restoreTrafficLights(in: window) }
                    }
                }
            )
            SiteChrome.placeTrafficLights(in: window)
        }
    }
}

/// Where the traffic lights sit, and what the page may ask of the window.
enum SiteChrome {
    /// Where the traffic lights sit: their left edge, and how far down the title bar reaches
    /// so their centre meets the middle of the site's 52pt toolbar. oeee-cafe/desktop's
    /// measure.
    private static let trafficLightsX: CGFloat = 20
    private static let trafficLightsY: CGFloat = 28.5

    /// Where AppKit laid the title bar and the buttons before they were moved, to give
    /// back for full screen: the title bar's height, and each button's left edge.
    private static var standard: (height: CGFloat, xs: [CGFloat])?

    private static func buttons(of window: NSWindow) -> (container: NSView, buttons: [NSButton])? {
        guard let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview?.superview else { return nil }
        return (container, [close, miniaturize, zoom])
    }

    static func placeTrafficLights(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let (container, buttons) = buttons(of: window) else { return }
        let (close, miniaturize) = (buttons[0], buttons[1])
        if standard == nil {
            standard = (container.frame.height, buttons.map(\.frame.minX))
        }
        let height = close.frame.height + trafficLightsY
        var frame = container.frame
        frame.size.height = height
        frame.origin.y = window.frame.height - height
        container.frame = frame
        let spacing = miniaturize.frame.minX - close.frame.minX
        for (index, button) in buttons.enumerated() {
            button.setFrameOrigin(NSPoint(x: trafficLightsX + CGFloat(index) * spacing, y: button.frame.minY))
        }
    }

    /// The title bar and its buttons as AppKit had them, for full screen to lay out;
    /// leaving full screen places them again (placeTrafficLights).
    static func restoreTrafficLights(in window: NSWindow) {
        guard let standard, let (container, buttons) = buttons(of: window) else { return }
        var frame = container.frame
        frame.size.height = standard.height
        frame.origin.y = window.frame.height - standard.height
        container.frame = frame
        for (button, x) in zip(buttons, standard.xs) {
            button.setFrameOrigin(NSPoint(x: x, y: button.frame.minY))
        }
    }

    /// What runs at the start of every page: the toolbar as the title bar (MacWindow.js),
    /// and a right-click menu kept to where it is useful (QuietContextMenu.js).
    static var userScripts: [WKUserScript] {
        [Scripts.macWindow, Scripts.quietContextMenu].map { Scripts.atDocumentStart($0) }
    }

    /// The window's chrome asking to drag or zoom `window` (a `window` message on the
    /// bridge, from MacWindow.js).
    static func windowAsked(_ action: String, of window: NSWindow?) {
        guard let window else { return }
        switch action {
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
