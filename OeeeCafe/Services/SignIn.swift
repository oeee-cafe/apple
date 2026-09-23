import WebKit

/// Signing in with Apple and with Google, for the site in the web view, on iOS and on the
/// Mac alike.
///
/// The site's "Sign in with Apple" and "Sign in with Google" go to the provider's page in a
/// browser. Here neither can: Apple's page would open in Safari -- the navigation delegate
/// sends anything that is not this site out of the app -- and answer into Safari's cookies
/// rather than the web view's, and Google refuses its own pages inside an embedded web view
/// (`disallowed_useragent`). So in the app the page takes the press itself, and the page and
/// the app carry the sign-in between them (app_sign_in.jinja in oeee-cafe/web, which is the
/// contract):
///
/// 1. the page asks the site for this sign-in's state and nonce (`POST
///    /auth/<provider>/start`), which the site keeps in the web view's session;
/// 2. the page sends `signIn {provider, nonce}` on the bridge (SiteBridge), and the app
///    runs the platform's own sheet for that nonce -- Apple's (AppleSignIn), or Google's
///    page in a browser of the system's (GoogleSignIn);
/// 3. the app answers with `window.oeeeApp.signIn.answer(told)`, and the page posts the token
///    and the state to `/auth/<provider>`, and the site checks both against the session
///    and signs in (src/apple.rs, src/google.rs and src/web/handlers/identity.rs).
///
/// Everything the site is asked is asked by the page, so it carries the page's cookie and
/// origin; the app never holds the session, never sees the state, and does not decide
/// where the page goes afterwards.
enum SignIn {
    /// What the sheet came to, as the page's `answer` takes it.
    enum Told {
        /// An ID token for the nonce, and for Apple the first time only, the person's name
        /// as Apple's page would post it (`{"name": {"firstName", "lastName"}}`).
        case signedIn(idToken: String, user: String?)
        /// Put away without signing in: the page stays as it was.
        case cancelled
        /// Could not sign in. The site is still asked, so that it says it could not confirm
        /// who this is in the page's own words.
        case failed

        var object: [String: Any] {
            switch self {
            case .signedIn(let idToken, let user):
                var told: [String: Any] = ["id_token": idToken]
                if let user { told["user"] = user }
                return told
            case .cancelled:
                return ["cancelled": true]
            case .failed:
                return [:]
            }
        }
    }

    /// Runs the sheet for the nonce the page was given (`signIn`, SiteBridge), and tells the
    /// page what it came to.
    static func sheet(_ provider: String, nonce: String, in webView: WKWebView) async {
        let told: Told
        switch provider {
        case "apple":
            told = await AppleSignIn.signIn(nonce: nonce, in: webView)
        case "google" where GoogleSignIn.isAvailable:
            told = await GoogleSignIn.signIn(nonce: nonce, in: webView)
        default:
            Logger.warning("SignIn: No sheet signs in with \(provider)", category: Logger.auth)
            told = .failed
        }
        _ = try? await webView.callAsyncJavaScript(
            "window.oeeeApp && window.oeeeApp.signIn && window.oeeeApp.signIn.answer(told);",
            arguments: ["told": told.object],
            in: nil,
            contentWorld: .page
        )
    }
}
