import AuthenticationServices
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Sign in with Apple, natively, for the site in a web view, on iOS and on the Mac alike.
///
/// The site's "Sign in with Apple" is a link to `/auth/apple`, which in a browser goes to
/// Apple's page and back. Here that would open Apple's page in Safari -- the navigation
/// delegate sends anything that is not this site out of the app, on both platforms -- and
/// the answer would come back to Safari's cookies rather than the web view's. So the tab
/// stops the link (WebTabController+Navigation.swift) and signs in here instead:
///
/// 1. the page asks the site for a state and a nonce (`POST /auth/apple/start`), which the
///    site keeps in the web view's session;
/// 2. Apple's own sheet signs in with that nonce and answers with an ID token;
/// 3. the page posts the token and the state to `/auth/apple`, as Apple's page would have,
///    and the site checks both against the session and signs in (src/apple.rs and
///    src/web/handlers/identity.rs in oeee-cafe/web).
///
/// Everything the site is asked is asked by the page, so it carries the page's cookie and
/// origin; the app never holds the session itself.
@MainActor
enum AppleSignIn {
    /// Whether `url` is the site's link to sign in with Apple.
    static func isSignInLink(_ navigationAction: WKNavigationAction, site: URL) -> Bool {
        guard let url = navigationAction.request.url else { return false }
        return url.host == site.host
            && url.path == "/auth/apple"
            && (navigationAction.request.httpMethod ?? "GET") == "GET"
    }

    /// Signs in with Apple for the page in `webView`, going on to `next` afterwards.
    static func signIn(in webView: WKWebView, next: String?) async {
        guard let started = await start(in: webView, next: next) else {
            Logger.warning("AppleSignIn: The site did not start a sign-in", category: Logger.auth)
            await stay(in: webView)
            return
        }

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = started.nonce

        let credential: ASAuthorizationAppleIDCredential
        do {
            credential = try await Authorization(anchor: webView.window).perform(request)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // Put away without signing in: the page stays as it was.
            await stay(in: webView)
            return
        } catch {
            Logger.warning("AppleSignIn: Apple did not sign in - \(error.localizedDescription)", category: Logger.auth)
            // The site says it could not confirm who this is, in the page's own words.
            await answer(in: webView, fields: ["state": started.state, "error": "failed"], next: next)
            return
        }

        guard let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
            await answer(in: webView, fields: ["state": started.state, "error": "failed"], next: next)
            return
        }
        var fields = ["state": started.state, "id_token": token]
        if let user = userField(credential.fullName) {
            fields["user"] = user
        }
        await answer(in: webView, fields: fields, next: next)
    }

    /// Shows the page as it was before the link was tapped. A page from before the site
    /// knew the app took this link slid a skeleton in over itself for the page it thought
    /// was coming (toolbar.jinja in oeee-cafe/web); nothing is coming, so it comes down,
    /// as it does when a page cannot be reached (WebTab.swift).
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
        const response = await fetch("/auth/apple/start", {
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

    /// Posts Apple's answer to `/auth/apple` from the page, which the site takes it from.
    ///
    /// Linking from the account page comes back to the account page (`next`), so there it
    /// is posted without leaving and the page is shown again where it is, with the site's
    /// word on how it went. Signing in goes on to wherever the site sends it.
    private static func answer(in webView: WKWebView, fields: [String: String], next: String?) async {
        let script = """
        if (next && next === location.pathname) {
          await fetch("/auth/apple", {
            method: "POST",
            credentials: "same-origin",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams(fields).toString(),
            // The site's redirect back here is not followed: following it would
            // show its message to the fetch rather than to the page.
            redirect: "manual",
          });
          location.reload();
          return;
        }
        const form = document.createElement("form");
        form.method = "post";
        form.action = "/auth/apple";
        form.style.display = "none";
        for (const [name, value] of Object.entries(fields)) {
          const input = document.createElement("input");
          input.type = "hidden";
          input.name = name;
          input.value = value;
          form.appendChild(input);
        }
        document.body.appendChild(form);
        form.submit();
        """
        _ = try? await webView.callAsyncJavaScript(
            script,
            arguments: ["fields": fields, "next": next ?? NSNull()],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    /// The person's name as Apple's page would post it (`{"name": {"firstName", "lastName"}}`),
    /// for a new account's display name. Apple gives it the first time only.
    private static func userField(_ name: PersonNameComponents?) -> String? {
        guard let name else { return nil }
        var parts: [String: String] = [:]
        if let given = name.givenName, !given.isEmpty { parts["firstName"] = given }
        if let family = name.familyName, !family.isEmpty { parts["lastName"] = family }
        guard !parts.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["name": parts])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One ASAuthorizationController run, as an async call. Holds itself until Apple answers.
    private final class Authorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        /// `UIWindow` on iOS, `NSWindow` on the Mac; `webView.window` is each.
        private let anchor: ASPresentationAnchor?
        private var controller: ASAuthorizationController?
        private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

        init(anchor: ASPresentationAnchor?) {
            self.anchor = anchor
        }

        func perform(_ request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorizationAppleIDCredential {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                self.controller = controller
                controller.performRequests()
            }
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            anchor ?? ASPresentationAnchor()
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                continuation?.resume(returning: credential)
            } else {
                continuation?.resume(throwing: ASAuthorizationError(.unknown))
            }
            continuation = nil
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
