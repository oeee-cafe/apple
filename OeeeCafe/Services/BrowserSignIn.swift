import AuthenticationServices
import WebKit
import os
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Signing in on the site's own web pages, in a browser of the system's, for the site in the
/// web view: Google and Discord, on iOS and on the Mac alike.
///
/// Google refuses its own sign-in pages inside an embedded web view
/// (`disallowed_useragent`), and there is no sheet of the platform's own for it as there is
/// for Apple (AppleSignIn). So the page hands the sign-in to a browser and waits for it
/// (app_sign_in.jinja and src/handoff.rs in oeee-cafe/web, which are the contract):
///
/// 1. the page starts a handoff (`POST /auth/handoff/start`) and sends `browse {url}` on the
///    bridge (SiteBridge): the provider's own sign-in page, Google's or Discord's, with a
///    state the site keeps against the handoff. Straight to the provider rather than through
///    the site, because the session first asks whether the app may use the first page's
///    domain to sign in, and the reader pressed Sign in with Google or Discord, not oeee.cafe;
/// 2. the app opens it in `ASWebAuthenticationSession` -- a browser of the system's, which
///    is what Google asks an app to use, and which the person's Safari sign-ins are already
///    in -- and the site's ordinary web sign-in runs there, ending on `/auth/handoff/done`,
///    which goes to `oeee-cafe://handoff/done?code=<code>`, and that closes the session;
/// 3. the app calls `window.oeeeApp.signIn.resume("<code>")`, and the page claims the
///    sign-in with it (`POST /auth/handoff/claim`) at once, rather than at its next turn of
///    asking. A callback without a code that is one (`isHandoffCode`) is still the browser
///    finishing, and the page is told `resume()` with nothing, as before. If the
///    browser could not be opened, or was put away, it calls
///    `window.oeeeApp.signIn.unopened()` instead: the page asks the site once more -- the
///    sheet may have been put away just after the sign-in finished -- and otherwise stops
///    waiting, so the button works again.
///
/// The browser signs nobody in to the web view: the page's claim does, with its own cookie.
/// What comes back through the app is the code alone, which the page sends with its claim;
/// the handoff's secret is not it, and stays in the page. The app passes the code on and
/// keeps nothing. It reaches the page as text inside a script, so only exactly 64 lowercase
/// hex digits are let through; anything else in the callback is dropped.
@MainActor
enum BrowserSignIn {
    /// What `/auth/handoff/done` goes to, which ends the session. Caught by
    /// `ASWebAuthenticationSession` itself, so nothing registers the scheme.
    static let callbackScheme = "oeee-cafe"

    /// The one browser open, which is held until it answers.
    private static var running: Authorization?

    /// The providers' sign-in pages, which the site sends a Google or Discord sign-in straight
    /// to (`handoff::AtProvider` in oeee-cafe/web).
    static let providerSignIns = [
        (host: "accounts.google.com", path: "/o/oauth2/v2/auth"),
        (host: "discord.com", path: "/oauth2/authorize"),
    ]

    /// `text` as a URL the browser may open: the site's own, or a provider's sign-in page, over
    /// https. The page says where to go, and this is what keeps a page from sending the app
    /// anywhere else.
    static func url(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https" else { return nil }
        if SiteURL.contains(url) { return url }
        guard url.user == nil, url.password == nil, url.port == nil else { return nil }
        let host = url.host?.lowercased()
        let isProvider = providerSignIns.contains { $0.host == host && $0.path == url.path }
        return isProvider ? url : nil
    }

    /// The handoff's code that `callback` (`oeee-cafe://handoff/done?code=<code>`) brings
    /// back, or nil when it brings none, or more than one, or one that is not a code. The
    /// site can only send one; a callback that differs is not taken a guess at.
    static func handoffCode(in callback: URL) -> String? {
        let codes = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "code" } ?? []
        guard codes.count == 1, let code = codes[0].value, isHandoffCode(code) else { return nil }
        return code
    }

    /// Whether `text` is a handoff's code as the site makes them: exactly 64 lowercase hex
    /// digits. This is what lets a code into a script (`Scripts.signInResume`), so it is
    /// checked byte by byte rather than trusted to come from the site.
    static func isHandoffCode(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 64 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Opens `text` over the window of `webView` (`browse`, SiteBridge), and tells the page
    /// how it went.
    static func open(_ text: String, in webView: WKWebView) async {
        guard let url = url(text) else {
            Logger.auth.warning("BrowserSignIn: Not opening a page that is not the site's")
            await tell(Scripts.signInUnopened, in: webView)
            return
        }
        // The browser covers the page, so a second press cannot come from the reader; this
        // is a page asking while one is open, and it is told no rather than closing the
        // other.
        guard running == nil else {
            Logger.auth.warning("BrowserSignIn: A browser is already open")
            await tell(Scripts.signInUnopened, in: webView)
            return
        }

        let authorization = Authorization(anchor: webView.window)
        running = authorization
        let script: String
        do {
            let returned = try await authorization.perform(url: url, callbackScheme: callbackScheme)
            script = Scripts.signInResume(code: handoffCode(in: returned))
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            script = Scripts.signInUnopened
        } catch {
            Logger.auth.warning("BrowserSignIn: The browser did not finish - \(error.localizedDescription, privacy: .public)")
            script = Scripts.signInUnopened
        }
        running = nil
        await tell(script, in: webView)
    }

    private static func tell(_ script: String, in webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    /// One `ASWebAuthenticationSession`, as an async call. Holds its session until it answers.
    private final class Authorization: NSObject, ASWebAuthenticationPresentationContextProviding {
        /// `UIWindow` on iOS, `NSWindow` on the Mac; `webView.window` is each.
        private let anchor: ASPresentationAnchor?
        private var session: ASWebAuthenticationSession?
        private var continuation: CheckedContinuation<URL, Error>?

        init(anchor: ASPresentationAnchor?) {
            self.anchor = anchor
        }

        func perform(url: URL, callbackScheme: String) async throws -> URL {
            defer { session = nil }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { [weak self] returned, error in
                    if let returned {
                        self?.answer(.success(returned))
                    } else {
                        self?.answer(.failure(error ?? ASWebAuthenticationSessionError(.canceledLogin)))
                    }
                }
                session.presentationContextProvider = self
                // The person's Google and Discord sign-ins live in Safari; an ephemeral
                // session would ask them for them again every time.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                if !session.start() {
                    answer(.failure(ASWebAuthenticationSessionError(.presentationContextInvalid)))
                }
            }
        }

        /// Answers once: a session that could not start is not expected to call its handler
        /// as well, but if it does, that is not a second answer.
        private func answer(_ result: Result<URL, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor ?? ASPresentationAnchor()
        }
    }
}
