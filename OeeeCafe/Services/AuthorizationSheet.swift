import AuthenticationServices
import WebKit

/// One of the system's sheets for signing in, over the window of a web view, as an async
/// call: Sign in with Apple (AppleSignIn), and a saved password (SavedPassword).
///
/// One at a time. The page asks for each on a press of its own, and two presses close
/// together would put a second controller up while the first's sheet is: the system shows
/// one, and ends the other at once, which the page would take for the reader putting it
/// away. So a sheet asked for while one is up is answered as put away, without a second
/// controller, and the one up carries on.
@MainActor
final class AuthorizationSheet: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private static var showing = false

    /// `request` in the system's sheet over `webView`'s window, and what the reader chose.
    /// Throws `ASAuthorizationError.canceled` without a sheet while another is up.
    static func perform(_ request: ASAuthorizationRequest, over webView: WKWebView) async throws -> ASAuthorization {
        guard !showing else { throw ASAuthorizationError(.canceled) }
        showing = true
        defer { showing = false }
        return try await AuthorizationSheet(anchor: webView.window).run(request)
    }

    /// `UIWindow` on iOS, `NSWindow` on the Mac; `webView.window` is each.
    private let anchor: ASPresentationAnchor?
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    private init(anchor: ASPresentationAnchor?) {
        self.anchor = anchor
    }

    /// Where `performRequests()` is called from, and only it; see `run`.
    private nonisolated static let flow = DispatchQueue(
        label: "cafe.oeee.authorization-sheet",
        qos: .utility
    )

    /// `performRequests()` sets the system's side of the flow up before it returns, waiting
    /// on a worker of AuthenticationServices' own at the default quality of service. Called
    /// from the main thread, which is user-interactive, that is the priority inversion the
    /// runtime complains of. It gives way to a queue of this class's own, fixed below the
    /// worker it waits on, since an explicit queue quality of service outranks the
    /// submitting context's. Nothing higher waits on anything lower either way round.
    ///
    /// Only the call goes there. The flow is set up here on the main actor, and the
    /// framework comes back to it of its own accord for the sheet and for the answer:
    /// `ASAuthorizationController` is not `NS_SWIFT_UI_ACTOR`, but both protocols it calls
    /// back through are.
    ///
    /// Holds itself until the system answers: this call's frame does, for as long as it
    /// waits, and the controller keeps its delegate only weakly.
    private func run(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
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
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
