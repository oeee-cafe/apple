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
        // Signing in is done on the sign-in tab, and that tab is not there once it has
        // worked: the page saying so would go with it, and the reader would be moved to
        // a Home tab that had to be fetched again, having seen the notice for as long as
        // it took to notice they were signed in. So the web view is handed over instead
        // of thrown away -- it is already showing the page they were sent to, notice and
        // all -- and Home's own, rendered for whoever was signed in before, goes in its
        // place.
        let leaving = controllers.keys.filter { !visibleTabs.contains($0) }
        if let signedInOn = leaving.first(where: { controllers[$0]?.lastSignedIn == signedIn }),
           visibleTabs.contains(.home),
           let arriving = controllers.removeValue(forKey: signedInOn) {
            controllers.removeValue(forKey: .home)?.tearDown()
            arriving.adopt(tab: .home)
            controllers[.home] = arriving
        }

        for tab in controllers.keys where !visibleTabs.contains(tab) {
            controllers.removeValue(forKey: tab)?.tearDown()
        }
        for controller in controllers.values where controller.lastSignedIn != signedIn {
            controller.webView.reload()
        }
    }
}
