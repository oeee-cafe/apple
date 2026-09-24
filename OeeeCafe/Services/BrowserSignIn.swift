import AuthenticationServices
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Signing in on the site's own web pages, in a browser of the system's, for the site in the
/// web view: Google, on iOS and on the Mac alike.
///
/// Google refuses its own sign-in pages inside an embedded web view
/// (`disallowed_useragent`), and there is no sheet of the platform's own for it as there is
/// for Apple (AppleSignIn). So the page hands the sign-in to a browser and waits for it
/// (app_sign_in.jinja and src/handoff.rs in oeee-cafe/web, which are the contract):
///
/// 1. the page starts a handoff (`POST /auth/handoff/start`) and sends `browse {url}` on the
///    bridge (SiteBridge), the URL of the site's own sign-in with the handoff in it;
/// 2. the app opens it in `ASWebAuthenticationSession` -- a browser of the system's, which
///    is what Google asks an app to use, and which the person's Safari sign-ins are already
///    in -- and the site's ordinary web sign-in runs there, ending on `/auth/handoff/done`,
///    which goes to `oeee-cafe://handoff/done`, and that closes the session;
/// 3. the app calls `window.oeeeApp.signIn.resume()`, and the page claims the sign-in
///    (`POST /auth/handoff/claim`) at once, rather than at its next turn of asking. If the
///    browser could not be opened, or was put away, it calls
///    `window.oeeeApp.signIn.unopened()` instead: the page asks the site once more -- the
///    sheet may have been put away just after the sign-in finished -- and otherwise stops
///    waiting, so the button works again.
///
/// The browser signs nobody in to the web view: the page's claim does, with its own cookie.
/// Nothing comes back through the app -- `oeee-cafe://handoff/done` carries nothing -- and
/// the app never sees the handoff's secret, which stays in the page.
@MainActor
enum BrowserSignIn {
    /// What `/auth/handoff/done` goes to, which ends the session. Caught by
    /// `ASWebAuthenticationSession` itself, so nothing registers the scheme.
    static let callbackScheme = "oeee-cafe"

    /// The one browser open, which is held until it answers.
    private static var running: Authorization?

    /// `text` as a URL the browser may open: only the site's own, over https. The page says
    /// where to go, and this is what keeps a page from sending the app anywhere else.
    static func url(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              SiteURL.contains(url) else { return nil }
        return url
    }

    /// Opens `text` over the window of `webView` (`browse`, SiteBridge), and tells the page
    /// how it went.
    static func open(_ text: String, in webView: WKWebView) async {
        guard let url = url(text) else {
            Logger.warning("BrowserSignIn: Not opening a page that is not the site's", category: Logger.auth)
            await tell(Scripts.signInUnopened, in: webView)
            return
        }
        // The browser covers the page, so a second press cannot come from the reader; this
        // is a page asking while one is open, and it is told no rather than closing the
        // other.
        guard running == nil else {
            Logger.warning("BrowserSignIn: A browser is already open", category: Logger.auth)
            await tell(Scripts.signInUnopened, in: webView)
            return
        }

        let authorization = Authorization(anchor: webView.window)
        running = authorization
        let script: String
        do {
            _ = try await authorization.perform(url: url, callbackScheme: callbackScheme)
            script = Scripts.signInResume
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            script = Scripts.signInUnopened
        } catch {
            Logger.warning("BrowserSignIn: The browser did not finish - \(error.localizedDescription)", category: Logger.auth)
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
                // The person's Google sign-in lives in Safari; an ephemeral session would
                // ask them for it again every time.
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
