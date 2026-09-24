import SwiftUI
import Combine

/// Pages to open from outside the app -- a push notification, a tapped oeee.cafe link --
/// held until there is a web view to open them in.
class NavigationCoordinator: ObservableObject {
    static let shared = NavigationCoordinator()

    /// A page to open from outside the app, until the web view takes it.
    @Published private(set) var pending: URL?

    private init() {}

    /// A page of the site, by its path (with any query), which the web view shows.
    func open(path: String) {
        Logger.debug("NavigationCoordinator: Opening \(path)", category: Logger.app)
        pending = SiteURL.page(path)
    }

    /// A link to the site from outside the app, opened on the site as the app reaches it
    /// whatever scheme or port the link was written with.
    func open(_ url: URL) {
        guard SiteURL.contains(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.scheme = SiteURL.root.scheme
        components.port = nil
        Logger.debug("NavigationCoordinator: Opening \(url)", category: Logger.app)
        pending = components.url
    }

    /// A tapped push notification opens the page it names (`url`, a path on the site,
    /// which the site works out for each kind of notification; every push it sends says one).
    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let path = userInfo["url"] as? String, path.hasPrefix("/"), !path.hasPrefix("//") else {
            Logger.warning("NavigationCoordinator: A notification without a page to open", category: Logger.app)
            return
        }
        open(path: path)
    }

    /// The page waiting, which is then no longer waiting.
    fileprivate func take() -> URL? {
        defer { pending = nil }
        return pending
    }
}

extension View {
    /// Opens in `controller` the page waiting when it appears, or else the site's front page,
    /// and every page handed to NavigationCoordinator after.
    func opensPages(in controller: WebController) -> some View {
        modifier(OpensPages(controller: controller))
    }
}

private struct OpensPages: ViewModifier {
    let controller: WebController
    @ObservedObject private var coordinator = NavigationCoordinator.shared

    func body(content: Content) -> some View {
        content
            .task {
                openPending()
                controller.start()
            }
            .onChange(of: coordinator.pending) {
                openPending()
            }
            // A tapped oeee.cafe link, from another app (applinks, the entitlements). The Mac
            // hands over most of them as an activity instead, which AppDelegate hears
            // (`application(_:continue:)`).
            .onOpenURL { url in
                coordinator.open(url)
            }
    }

    private func openPending() {
        guard let url = coordinator.take() else { return }
        controller.load(url)
    }
}
