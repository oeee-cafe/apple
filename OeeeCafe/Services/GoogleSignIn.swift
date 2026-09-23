import AuthenticationServices
import CryptoKit
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Sign in with Google, for the site in a web view, on iOS and on the Mac alike.
///
/// The site's "Sign in with Google" is a link to `/auth/google`, which in a browser goes to
/// Google's page and back. Google refuses its own sign-in pages inside an embedded web view
/// (`disallowed_useragent`). So the tab stops the link (WebTabController+Navigation.swift)
/// and signs in here, in `ASWebAuthenticationSession` -- a browser of the system's, which is
/// what Google asks an app to use, and which the person's Safari sign-ins are already in.
///
/// The Mac app is the same web view with the same bundle id, so it signs in against the same
/// OAuth client and takes the same path; only the window the sheet hangs from differs.
///
/// 1. the page asks the site for a state and a nonce (`POST /auth/google/start`), which the
///    site keeps in the web view's session;
/// 2. Google's page signs in with that nonce and comes back with a code, which this trades
///    for an ID token -- a public client with PKCE, so there is no secret in the app;
/// 3. the page posts the token and the state to `/auth/google`, and the site checks both
///    against the session and signs in (src/google.rs and src/web/handlers/identity.rs in
///    oeee-cafe/web).
///
/// Everything the site is asked is asked by the page, so it carries the page's cookie and
/// origin; the app never holds the session itself. The token this ends up with names the
/// app's own OAuth client as audience, which is what the site's `[google].app_ids` lists.
@MainActor
enum GoogleSignIn {
    /// The iOS OAuth client id, from `GoogleClientID` in the app's Info.plist (Google Cloud
    /// console > APIs & Services > Credentials > iOS). Empty when the build has none.
    static let clientID: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }()

    static var isAvailable: Bool { !clientID.isEmpty }

    /// Where Google comes back to: the client id, reversed, as Google issues it for iOS.
    /// `ASWebAuthenticationSession` catches this itself, so nothing registers the scheme.
    private static var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private static var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    private static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"

    /// Whether `url` is the site's link to sign in with Google.
    static func isSignInLink(_ navigationAction: WKNavigationAction, site: URL) -> Bool {
        guard isAvailable, let url = navigationAction.request.url else { return false }
        return url.host == site.host
            && url.path == "/auth/google"
            && (navigationAction.request.httpMethod ?? "GET") == "GET"
    }

    /// Signs in with Google for the page in `webView`, going on to `next` afterwards.
    static func signIn(in webView: WKWebView, next: String?) async {
        guard let started = await start(in: webView, next: next) else {
            Logger.warning("GoogleSignIn: The site did not start a sign-in", category: Logger.auth)
            await stay(in: webView)
            return
        }

        let verifier = codeVerifier()
        let code: String
        do {
            code = try await authorize(
                in: webView,
                state: started.state,
                nonce: started.nonce,
                challenge: codeChallenge(for: verifier)
            )
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Put away without signing in: the page stays as it was.
            await stay(in: webView)
            return
        } catch {
            Logger.warning("GoogleSignIn: Google did not sign in - \(error.localizedDescription)", category: Logger.auth)
            // The site says it could not confirm who this is, in the page's own words.
            await answer(in: webView, fields: ["state": started.state, "error": "failed"])
            return
        }

        guard let token = await exchange(code: code, verifier: verifier) else {
            await answer(in: webView, fields: ["state": started.state, "error": "failed"])
            return
        }
        await answer(in: webView, fields: ["state": started.state, "id_token": token])
    }

    /// Shows the page as it was before the link was tapped, as AppleSignIn does.
    private static func stay(in webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript("window.oeeeRestoreContent && window.oeeeRestoreContent();")
    }

    private struct Started {
        let state: String
        let nonce: String
    }

    /// Asks the site, from the page, for this sign-in's state and nonce.
    private static func start(in webView: WKWebView, next: String?) async -> Started? {
        let script = """
        const body = new URLSearchParams();
        if (next) body.set("next", next);
        const response = await fetch("/auth/google/start", {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: body.toString(),
        });
        if (!response.ok) return null;
        return await response.json();
        """
        let result = try? await webView.callAsyncJavaScript(
            script,
            arguments: ["next": next ?? NSNull()],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let answer = result as? [String: Any],
              let state = answer["state"] as? String,
              let nonce = answer["nonce"] as? String
        else { return nil }
        return Started(state: state, nonce: nonce)
    }

    /// Google's page, in a browser of the system's, and the code it comes back with.
    /// `state` is the site's, echoed by Google and compared here, so a redirect that is
    /// not this sign-in's answer is not taken for one.
    private static func authorize(
        in webView: WKWebView,
        state: String,
        nonce: String,
        challenge: String
    ) async throws -> String {
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        let returned = try await Authorization(anchor: webView.window)
            .perform(url: components.url!, callbackScheme: callbackScheme)
        let answer = URLComponents(url: returned, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            answer.first(where: { $0.name == name })?.value
        }
        guard value("state") == state, let code = value("code"), !code.isEmpty else {
            throw ASWebAuthenticationSessionError(.presentationContextInvalid)
        }
        return code
    }

    /// Trades the code for an ID token, as a public client: the verifier stands in for a
    /// secret, so there is none in the app.
    private static func exchange(code: String, verifier: String) async -> String? {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                Logger.warning("GoogleSignIn: Google would not trade the code (\(status))", category: Logger.auth)
                return nil
            }
            let answer = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let token = answer?["id_token"] as? String, !token.isEmpty else {
                Logger.warning("GoogleSignIn: Google traded the code for no ID token", category: Logger.auth)
                return nil
            }
            return token
        } catch {
            Logger.warning("GoogleSignIn: Could not reach Google - \(error.localizedDescription)", category: Logger.auth)
            return nil
        }
    }

    /// Posts the answer to `/auth/google` from the page, which the site takes it from.
    ///
    /// The site says where it would have sent a browser rather than sending one, and the
    /// page goes there itself, replacing where it is: signing in and linking are then the
    /// same one step, and neither leaves the page it started from in the history.
    private static func answer(in webView: WKWebView, fields: [String: String]) async {
        let script = """
        const body = new URLSearchParams(fields);
        body.set("format", "json");
        const response = await fetch("/auth/google", {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: body.toString(),
        });
        if (!response.ok) return;
        const answer = await response.json();
        // Replaced, not followed: the page signed in from is not left in the
        // history behind the one it lands on, so Back does not return to a
        // sign-in form for an account already signed in. The site's notice is
        // waiting in the session and is shown by the page this replaces with.
        location.replace(answer.next || "/");
        """
        _ = try? await webView.callAsyncJavaScript(
            script,
            arguments: ["fields": fields],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    /// PKCE: a secret this sign-in makes up, sent to Google only as its SHA-256, so a code
    /// caught on the way back cannot be traded by anything that did not start the sign-in.
    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// One `ASWebAuthenticationSession`, as an async call. Holds itself until it answers.
    private final class Authorization: NSObject, ASWebAuthenticationPresentationContextProviding {
        /// `UIWindow` on iOS, `NSWindow` on the Mac; `webView.window` is each.
        private let anchor: ASPresentationAnchor?
        private var session: ASWebAuthenticationSession?

        init(anchor: ASPresentationAnchor?) {
            self.anchor = anchor
        }

        @MainActor
        func perform(url: URL, callbackScheme: String) async throws -> URL {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { returned, error in
                    if let returned {
                        continuation.resume(returning: returned)
                    } else {
                        continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                    }
                }
                session.presentationContextProvider = self
                // The person's Google sign-in lives in Safari; an ephemeral session would
                // ask them for it again every time.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                session.start()
            }
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor ?? ASPresentationAnchor()
        }
    }
}
