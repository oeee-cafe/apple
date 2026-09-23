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
/// (`disallowed_useragent`). So in the app the page takes the press itself and carries the
/// sign-in (SignIn.swift, app_sign_in.jinja in oeee-cafe/web); this is the part only the app can
/// do: Google's page in `ASWebAuthenticationSession` -- a browser of the system's, which is
/// what Google asks an app to use, and which the person's Safari sign-ins are already in --
/// with the nonce the page was given, and the code it comes back with traded for an ID
/// token. The trade stays here: this is a public client with PKCE, so there is no secret in
/// the app, and nothing the site would need to hold.
///
/// The Mac app is the same web view with the same bundle id, so it signs in against the same
/// OAuth client and takes the same path; only the window the sheet hangs from differs.
///
/// The token this ends up with names the app's own OAuth client as audience, which is what
/// the site's `[google].app_ids` lists.
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

    /// Google's page, over the window of `webView`, for `nonce`, and what it came to.
    static func signIn(nonce: String, in webView: WKWebView) async -> SignIn.Told {
        let verifier = codeVerifier()
        let code: String
        do {
            code = try await authorize(
                in: webView,
                nonce: nonce,
                challenge: codeChallenge(for: verifier)
            )
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return .cancelled
        } catch {
            Logger.warning("GoogleSignIn: Google did not sign in - \(error.localizedDescription)", category: Logger.auth)
            return .failed
        }

        guard let token = await exchange(code: code, verifier: verifier) else {
            return .failed
        }
        return .signedIn(idToken: token, user: nil)
    }

    /// Google's page, in a browser of the system's, and the code it comes back with.
    ///
    /// `state` is made up here for this one trip and compared when Google echoes it, so a
    /// redirect that is not this sign-in's answer is not taken for one. It is the app's
    /// own: the site's state stays in the page, which posts it with the token, and never
    /// passes through the app.
    private static func authorize(
        in webView: WKWebView,
        nonce: String,
        challenge: String
    ) async throws -> String {
        let state = randomString()
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

    /// PKCE: a secret this sign-in makes up, sent to Google only as its SHA-256, so a code
    /// caught on the way back cannot be traded by anything that did not start the sign-in.
    private static func codeVerifier() -> String {
        randomString()
    }

    /// 32 random bytes, base64url: a verifier, or a state.
    private static func randomString() -> String {
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
