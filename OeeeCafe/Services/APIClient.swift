import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .networkError(let error):
            let nsError = error as NSError
            return "Network error: \(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))"
        case .status(let code):
            return "The server answered \(code)"
        }
    }
}

/// The site's API, for the little the app asks of it itself -- registering this device's
/// push token. Everything else is the site's pages, in the web views.
///
/// Requests go as whoever is signed in on the web views, with their cookies (WebSession),
/// and nothing the API sets is kept: the web views' session is the only one.
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    /// The status the site answers a GET of `path` with, as whoever is signed in on the web
    /// views; nil when it could not be asked.
    func status(path: String) async -> Int? {
        guard let url = URL(string: APIConfig.shared.baseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in await WebSession.shared.cookieHeader(for: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// Posts `body` as JSON (snake_case keys) and checks that it was taken.
    func post<Body: Encodable>(path: String, body: Body) async throws {
        guard let url = URL(string: APIConfig.shared.baseURL + path) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in await WebSession.shared.cookieHeader(for: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            Logger.warning("POST \(path): Status \(status)", category: Logger.network)
            throw APIError.status(status)
        }
    }
}
