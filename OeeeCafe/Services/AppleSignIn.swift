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
/// Apple's page and back. Here that would open Apple's page in Safari, and the answer would
/// come back to Safari's cookies rather than the web view's. So in the app the page takes the
/// press itself and carries the sign-in (SignIn.swift, app_sign_in.jinja in oeee-cafe/web);
/// this is the part only the app can do, Apple's own sheet, which signs in with the nonce the page
/// was given and answers with an ID token.
@MainActor
enum AppleSignIn {
    /// Apple's sheet, over the window of `webView`, for `nonce`, and what it came to.
    static func signIn(nonce: String, in webView: WKWebView) async -> SignIn.Told {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce

        let credential: ASAuthorizationAppleIDCredential
        do {
            credential = try await Authorization(anchor: webView.window).perform(request)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return .cancelled
        } catch {
            Logger.warning("AppleSignIn: Apple did not sign in - \(error.localizedDescription)", category: Logger.auth)
            return .failed
        }

        guard let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
            Logger.warning("AppleSignIn: Apple signed in with no ID token", category: Logger.auth)
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

    /// One ASAuthorizationController run, as an async call. Holds itself until Apple answers.
    private final class Authorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        /// `UIWindow` on iOS, `NSWindow` on the Mac; `webView.window` is each.
        private let anchor: ASPresentationAnchor?
        private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

        init(anchor: ASPresentationAnchor?) {
            self.anchor = anchor
        }

        /// Where `performRequests()` is called from, and only it; see `perform`.
        private nonisolated static let flow = DispatchQueue(
            label: "cafe.oeee.apple-sign-in",
            qos: .utility
        )

        /// `performRequests()` sets Apple's side of the flow up before it returns, waiting on
        /// a worker of AuthenticationServices' own at the default quality of service. Called
        /// from the main thread, which is user-interactive, that is the priority inversion the
        /// runtime complains of -- the same shape as the cookie storage in WebSession, and it
        /// gives way to the same lever: a queue of this class's own, fixed below the worker it
        /// waits on, since an explicit queue quality of service outranks the submitting
        /// context's. Nothing higher waits on anything lower either way round.
        ///
        /// Only the call goes there. The flow is set up here on the main actor, and the
        /// framework comes back to it of its own accord for the sheet and for the answer:
        /// `ASAuthorizationController` is not `NS_SWIFT_UI_ACTOR`, but both protocols it calls
        /// back through are.
        func perform(_ request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorizationAppleIDCredential {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                // Nothing here holds the controller: AuthenticationServices keeps it until it
                // has called the delegate, which is the whole of its life.
                nonisolated(unsafe) let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                Self.flow.async { controller.performRequests() }
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
