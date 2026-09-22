import Foundation
import WebKit

/// The web views' cookies, which are the app's session: whoever is signed in on them is
/// who the app is (AuthService hears it from the pages), and the few requests the app makes
/// itself (APIClient) carry the same cookies.
final class WebSession {
    static let shared = WebSession()

    let dataStore = WKWebsiteDataStore.default()

    private init() {}

    private var site: URL? {
        URL(string: APIConfig.shared.baseURL)
    }

    /// Carries over a session signed in natively, before the app became a web view: its
    /// cookies were in HTTPCookieStorage, and the web views start from them if they have
    /// none of their own. Nothing reads that storage any more, so the copies are dropped
    /// once the web views have what they need -- left, they would go stale and could sign
    /// the web views back in as someone long signed out, the next time they were empty.
    func start() async {
        let store = dataStore.httpCookieStore
        let storage = HTTPCookieStorage.shared
        let native = (storage.cookies ?? []).filter(matchesSite)
        guard !native.isEmpty else { return }
        if !(await store.allCookies()).contains(where: matchesSite) {
            Logger.info("WebSession: Carrying over the native app's session", category: Logger.auth)
            for cookie in native {
                await store.setCookie(cookie)
            }
        }
        native.forEach(storage.deleteCookie)
    }

    /// The `Cookie` header the web views would send to `url`.
    func cookieHeader(for url: URL) async -> [String: String] {
        let cookies = await dataStore.httpCookieStore.allCookies().filter { cookie in
            matchesSite(cookie)
                && url.path.hasPrefix(cookie.path)
                && (!cookie.isSecure || url.scheme == "https")
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        return HTTPCookie.requestHeaderFields(with: cookies)
    }

    // MARK: - The device cookie

    /// Named in the site's sign-out (`oeee_device`, src/web/handlers/auth.rs in
    /// oeee-cafe/web): signing out on the site's page deletes the device whose push token
    /// this holds, so a device signed out gets no more of that account's notifications.
    /// The app used to stop the sign-out form on its way and delete the device first.
    private static let deviceCookieName = "oeee_device"

    /// Says which device this is, to the site's sign-out.
    func setDeviceCookie(_ token: String) async {
        guard let host = site?.host else { return }
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: Self.deviceCookieName,
            .value: token,
            .domain: host,
            .path: "/",
            .secure: "TRUE",
            // As long as the token is this device's, which a sign-in says again.
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 365),
        ]
        guard let cookie = HTTPCookie(properties: properties) else { return }
        await dataStore.httpCookieStore.setCookie(cookie)
    }

    private func matchesSite(_ cookie: HTTPCookie) -> Bool {
        guard let host = site?.host else { return false }
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return host == domain || host.hasSuffix("." + domain)
    }
}
