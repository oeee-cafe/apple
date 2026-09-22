import Foundation
import Combine

/// Pages to open from outside the app -- a push notification, a tapped oeee.cafe link --
/// held until there is a web view to open them in.
class NavigationCoordinator: ObservableObject {
    static let shared = NavigationCoordinator()

    /// A page to open from outside the app, and the tab to open it in.
    @Published var pendingNavigation: PendingNavigation?

    private init() {}

    struct PendingNavigation: Equatable {
        let tab: WebTab
        let path: String
        /// Whether the page is to be fetched again. A page opened from outside the app is
        /// what the reader came for, and is shown afresh; a section they stepped into from
        /// another tab is left as its tab had it, where they were in it and all.
        var fresh = true

        var url: URL? {
            URL(string: APIConfig.shared.baseURL + path)
        }
    }

    /// A page of the site, by its path (with any query), shown in the tab it belongs to.
    func open(path: String) {
        let tab = WebTab.showing(path: URLComponents(string: path)?.path ?? path)
        Logger.debug("NavigationCoordinator: Opening \(path) in \(tab.rawValue) tab", category: Logger.app)
        pendingNavigation = PendingNavigation(tab: tab, path: path)
    }

    /// A section of the site with a tab of its own, reached from another tab: the reader
    /// is taken to the tab it is, which shows it already or is sent to it.
    func show(section tab: WebTab) {
        Logger.debug("NavigationCoordinator: Showing the \(tab.rawValue) tab, its own section", category: Logger.app)
        pendingNavigation = PendingNavigation(tab: tab, path: tab.path, fresh: false)
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
