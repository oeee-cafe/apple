import Foundation
import Combine

/// Pages to open from outside the app -- a push notification, a tapped oeee.cafe link --
/// held until there is a web view to open them in.
class NavigationCoordinator: ObservableObject {
    static let shared = NavigationCoordinator()

    /// A page to open from outside the app.
    @Published var pendingNavigation: PendingNavigation?

    private init() {}

    struct PendingNavigation: Equatable {
        let path: String

        var url: URL? {
            URL(string: APIConfig.shared.baseURL + path)
        }
    }

    /// A page of the site, by its path (with any query). The web view shows it, and the
    /// tab bar draws whichever section it turns out to be in (WebTabController.section).
    func open(path: String) {
        Logger.debug("NavigationCoordinator: Opening \(path)", category: Logger.app)
        pendingNavigation = PendingNavigation(path: path)
    }

    /// A link to the site from outside the app.
    func open(_ url: URL) {
        guard let site = URL(string: APIConfig.shared.baseURL), url.host == site.host,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.scheme = nil
        components.host = nil
        components.port = nil
        open(path: components.string ?? url.path)
    }

    /// A tapped push notification opens the page it names (`url`, a path on the site,
    /// which the site works out for each kind of notification), or the notifications,
    /// where every one of them can be found.
    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let path = userInfo["url"] as? String, path.hasPrefix("/"), !path.hasPrefix("//") else {
            Logger.warning("NavigationCoordinator: A notification without a page to open", category: Logger.app)
            open(path: WebTab.notifications.path)
            return
        }
        open(path: path)
    }

    /// Clear pending navigation after it has been processed
    func clearPendingNavigation() {
        pendingNavigation = nil
    }
}
