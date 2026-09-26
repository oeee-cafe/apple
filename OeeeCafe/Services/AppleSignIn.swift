import AuthenticationServices
import WebKit
import os
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Sign in with Apple, natively, for the site in a web view, on iOS and on the Mac alike.
///
/// The site's "Sign in with Apple" is a link to `/auth/apple`, which in a browser goes to
/// Apple's page and back. Here that would open Apple's page in Safari, and the answer would
/// come back to Safari's cookies rather than the web view's. So in the app the page takes the
/// press itself and carries the sign-in (SignIn.swift, app_sign_in.jinja in oeee-cafe/web);
/// this is the part only the app can do, Apple's own sheet, which signs in with the nonce the page
/// was given and answers with an ID token.
@MainActor
enum AppleSignIn {
    /// Apple's sheet, over the window of `webView`, for `nonce`, and what it came to.
    static func signIn(nonce: String?, in webView: WKWebView) async -> SignIn.Told {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce

        let credential: ASAuthorizationAppleIDCredential
        do {
            let authorization = try await AuthorizationSheet.perform(request, over: webView)
            guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential else {
                throw ASAuthorizationError(.unknown)
            }
            credential = apple
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return .cancelled
        } catch {
            Logger.auth.warning("AppleSignIn: Apple did not sign in - \(error.localizedDescription, privacy: .public)")
            return .failed
        }

        guard let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
            Logger.auth.warning("AppleSignIn: Apple signed in with no ID token")
            return .failed
        }
        return .signedIn(idToken: token, user: userField(credential.fullName))
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
}
