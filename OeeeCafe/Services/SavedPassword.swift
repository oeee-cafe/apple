import AuthenticationServices
import WebKit
import os

/// A password saved for the site, offered in the system's sheet, for the page to fill its
/// form with (app_saved_password.jinja in oeee-cafe/web, which is the contract).
///
/// Safari fills a form from the reader's saved passwords, and on iOS the keyboard offers
/// them in any app's web view. A web view in a Mac app gets neither: the Mac offers them
/// only on its own text fields. So the page asks, when the reader presses or tabs to a
/// field of a sign-in form (`password {id}`, SiteBridge), and the app asks the system for a
/// password saved for a domain it names (`webcredentials:oeee.cafe`, the entitlements, and
/// the site's apple-app-site-association). Only the Mac's pages ask.
///
/// The password goes to the page on screen and nowhere else: the page is the site's own --
/// the bridge hears only the main frame -- and it fills the form the reader was about to
/// type it into.
@MainActor
enum SavedPassword {
    /// The sheet, and what it came to for the page's `password.answer`: the username and
    /// password picked, or `cancelled` for none -- put away, none saved, or a sheet already
    /// up (AuthorizationSheet) -- when the reader types, as they would have.
    static func offer(id: String, in webView: WKWebView) async {
        var told: [String: Any] = ["id": id]
        do {
            let request = ASAuthorizationPasswordProvider().createRequest()
            let authorization = try await AuthorizationSheet.perform(request, over: webView)
            guard let credential = authorization.credential as? ASPasswordCredential else {
                throw ASAuthorizationError(.unknown)
            }
            told["username"] = credential.user
            told["password"] = credential.password
        } catch let error as ASAuthorizationError where error.code == .canceled {
            told["cancelled"] = true
        } catch {
            // None saved for the site comes this way too, without a sheet: nothing to offer.
            Logger.auth.info("SavedPassword: none given - \(error.localizedDescription, privacy: .public)")
            told["cancelled"] = true
        }
        _ = try? await webView.callAsyncJavaScript(
            Scripts.passwordAnswer,
            arguments: ["told": told],
            in: nil,
            contentWorld: .page
        )
    }
}
