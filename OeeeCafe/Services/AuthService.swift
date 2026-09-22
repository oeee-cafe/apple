import Foundation
import Combine

/// Whether someone is signed in on the site, as its pages say (`page.signedIn`, SiteBridge),
/// and as the site answers once when the app opens.
///
/// Signing in and out happens on the web views, and every page with the toolbar says which
/// it was rendered for, so the app asks nobody: it listens. The last word is remembered, so
/// the app opens with the tabs it closed with rather than turning over once the first page
/// has spoken.
class AuthService: ObservableObject {
    static let shared = AuthService()

    private static let key = "signed_in"

    @Published private(set) var isAuthenticated: Bool

    private init() {
        isAuthenticated = UserDefaults.standard.bool(forKey: Self.key)
    }

    /// Asks the site once, as the app opens, before any page has said. A page says as soon
    /// as it loads, but only a site that sends bridge messages says anything: without this,
    /// an app opened against one that does not -- a site deployed after the app, or a first
    /// launch with nothing remembered -- shows the Login tab over a signed-in page for as
    /// long as it runs. Offline, or any other answer, leaves what was remembered.
    @MainActor
    func checkOnce() async {
        switch await APIClient.shared.status(path: "/api/v1/auth/me") {
        case 200?:
            pageSaid(signedIn: true)
        case 401?, 403?:
            pageSaid(signedIn: false)
        default:
            break
        }
    }

    /// What a page said about who it was rendered for.
    func pageSaid(signedIn: Bool) {
        guard signedIn != isAuthenticated else { return }
        Logger.info("AuthService: The site says \(signedIn ? "signed in" : "signed out")", category: Logger.auth)
        isAuthenticated = signedIn
        UserDefaults.standard.set(signedIn, forKey: Self.key)
    }
}
