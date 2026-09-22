import Foundation
import Combine

/// Who is signed in on the site. Signing in and out happens on the web views; `WebSession`
/// asks for a re-check whenever their cookies change.
class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isAuthenticated: Bool = false
    @Published var currentUser: CurrentUser?

    private let apiClient = APIClient.shared

    private init() {}

    func checkAuthStatus() async {
        Logger.debug("Checking auth status...", category: Logger.auth)

        do {
            let user: CurrentUser = try await apiClient.fetch(path: "/api/v1/auth/me")
            Logger.debug("User authenticated - \(user.loginName)", category: Logger.auth)
            currentUser = user
            isAuthenticated = true
        } catch {
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
