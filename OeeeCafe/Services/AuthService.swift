import Foundation
import Combine

/// Whether someone is signed in on the site, as its pages say (`page.signedIn`, SiteBridge).
///
/// Signing in and out happens on the web views, and every page with the toolbar says which
/// it was rendered for, so the app asks nobody: it listens. The last word is remembered, so
/// the app opens with the tabs it closed with rather than turning over once the first page
/// has spoken. A page restored from the back-forward cache is not believed until the
/// reader has gone on from it (WebTabController's `restored`).
class AuthService: ObservableObject {
    static let shared = AuthService()

    private static let key = "signed_in"

    @Published private(set) var isAuthenticated: Bool

    private init() {
        isAuthenticated = UserDefaults.standard.bool(forKey: Self.key)
    }

    /// What a page said about who it was rendered for.
    func pageSaid(signedIn: Bool) {
        guard signedIn != isAuthenticated else { return }
        Logger.info("AuthService: The site says \(signedIn ? "signed in" : "signed out")", category: Logger.auth)
        isAuthenticated = signedIn
        UserDefaults.standard.set(signedIn, forKey: Self.key)
    }
}
