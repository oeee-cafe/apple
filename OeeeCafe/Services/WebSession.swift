import Foundation
import WebKit

/// Keeps the native side (APIClient, push registration, badge counts) signed in as whoever
/// is signed in on the web views, by mirroring WKWebView's cookies into HTTPCookieStorage.
final class WebSession: NSObject, WKHTTPCookieStoreObserver {
    static let shared = WebSession()

    let dataStore = WKWebsiteDataStore.default()
    private var syncTask: Task<Void, Never>?
    private var lastSignature: String?

    private override init() {}

    private var host: String? {
        URL(string: APIConfig.shared.baseURL)?.host
    }

    /// Seeds the web views with the cookies of a session signed in natively (before the
    /// app became a web view), then starts following the web views' cookies.
    func start() async {
        let store = dataStore.httpCookieStore
        let webCookies = await store.allCookies()
        if !webCookies.contains(where: matchesHost) {
            for cookie in (HTTPCookieStorage.shared.cookies ?? []).filter(matchesHost) {
                await store.setCookie(cookie)
            }
        }
        store.add(self)
        await syncCookiesToNative()
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await syncCookiesToNative()
        }
    }

    private func matchesHost(_ cookie: HTTPCookie) -> Bool {
        guard let host else { return false }
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return host == domain || host.hasSuffix("." + domain)
    }

    private func syncCookiesToNative() async {
        let webCookies = await dataStore.httpCookieStore.allCookies().filter(matchesHost)
        let storage = HTTPCookieStorage.shared
        for cookie in (storage.cookies ?? []).filter(matchesHost) {
            storage.deleteCookie(cookie)
        }
        for cookie in webCookies {
            storage.setCookie(cookie)
        }

        // Only re-check who is signed in when the cookies actually changed.
        let signature = webCookies
            .map { "\($0.domain)\($0.path)\($0.name)=\($0.value)" }
            .sorted()
            .joined(separator: ";")
        guard signature != lastSignature else { return }
        lastSignature = signature
        Logger.debug("WebSession: Cookies changed, checking auth status", category: Logger.auth)
        await AuthService.shared.checkAuthStatus()
    }
}
