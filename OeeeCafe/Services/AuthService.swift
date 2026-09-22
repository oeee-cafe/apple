import Foundation
import Combine

/// Who is signed in on the site. Signing in and out happens on the web views; `WebSession`
/// asks for a re-check whenever their cookies change.
class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isAuthenticated: Bool = false
    @Published var currentUser: CurrentUser?

    private let apiClient = APIClient.shared
    private var connectivity: AnyCancellable?
    /// Whether the last check could not reach the site, and so said nothing either way.
    private var checkMissed = false

    private init() {
        // A check that could not be made is made again once it can.
        connectivity = Connectivity.shared.restored.sink { [weak self] in
            guard let self, self.checkMissed else { return }
            Task { await self.checkAuthStatus() }
        }
    }

    func checkAuthStatus() async {
        Logger.debug("Checking auth status...", category: Logger.auth)

        do {
            let user: CurrentUser = try await apiClient.fetch(path: "/api/v1/auth/me")
            Logger.debug("User authenticated - \(user.loginName)", category: Logger.auth)
            currentUser = user
            isAuthenticated = true
            checkMissed = false
        } catch APIError.networkError(let error) {
            // Offline is not signed out: whoever was signed in still is.
            guard !Task.isCancelled else { return }
            Logger.warning("Auth check could not reach the site - \(error.localizedDescription)", category: Logger.auth)
            checkMissed = true
        } catch {
            checkMissed = false
            // A check cancelled for a newer one says nothing about who is signed in.
            guard !Task.isCancelled else { return }
            Logger.warning("Auth check failed - \(error.localizedDescription)", category: Logger.auth)
            currentUser = nil
            isAuthenticated = false
        }
    }
}

struct CurrentUser: Codable, Identifiable {
    let id: String
    let loginName: String
    let displayName: String
}
