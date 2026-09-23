import Foundation
import Combine
import WebKit

/// Owns one long-lived web view per tab, so each tab keeps its own history and scroll position.
final class WebTabStore: ObservableObject {
    private var controllers: [WebTab: WebTabController] = [:]

    func controller(for tab: WebTab) -> WebTabController {
        if let controller = controllers[tab] {
            return controller
        }
        let controller = WebTabController(tab: tab)
        controllers[tab] = controller
        return controller
    }

    /// After signing in or out, every page shown so far was rendered for the other user.
    /// Drops the tabs that are no longer shown and reloads the rest -- but not the one
    /// already showing the new answer. Signing in ends on a page rendered for whoever
    /// just signed in, and that page is what reports it; reloading it throws away what it
    /// was rendered to say, which is the notice telling them it worked.
    func authenticationChanged(visibleTabs: [WebTab], signedIn: Bool) {
        for tab in controllers.keys where !visibleTabs.contains(tab) {
            controllers.removeValue(forKey: tab)?.tearDown()
        }
        for controller in controllers.values where controller.lastSignedIn != signedIn {
            controller.webView.reload()
        }
    }
}
