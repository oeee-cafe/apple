import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
import SafariServices
#endif

/// Where a link may go: the site's own pages stay in the web view, everything else goes
/// outside the app, and a page holding a drawing asks before it is left.
extension WebTabController: WKNavigationDelegate {
    func isSiteURL(_ url: URL) -> Bool {
        url.host == tab.rootURL.host
    }

    /// Another site, or another kind of link. On the Mac, the reader's browser. On iOS a web
    /// page goes to the app that claims it, if one is installed, and otherwise opens in a
    /// Safari sheet over this one, with Done to come back; mail, phone and the like go to
    /// the system.
    func openOutside(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        guard url.scheme == "http" || url.scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        Task {
            if await UIApplication.shared.open(url, options: [.universalLinksOnly: true]) {
                return
            }
            guard let presenter = JavaScriptDialog.presenter(for: webView) else {
                await UIApplication.shared.open(url)
                return
            }
            let safari = SFSafariViewController(url: url)
            safari.dismissButtonStyle = .done
            presenter.present(safari, animated: true)
        }
        #endif
    }

    /// Where a sign-in link says to go on to afterwards (`?next=`).
    private static func next(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "next" })?.value
    }

    /// Whether a failed load is the site being out of reach -- no network, no answer --
    /// rather than a load the app or the page called off.
    private static func isUnreachable(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code != NSURLErrorCancelled
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let isWebURL = url.scheme == "http" || url.scheme == "https"

        // Other sites (and mailto: etc.) open outside the app; embeds in frames load as usual.
        if isMainFrame && !(isWebURL && isSiteURL(url)) && url.scheme != "about" && url.scheme != "blob" && url.scheme != "data" {
            openOutside(url)
            return .cancel
        }
        #if os(iOS)
        // Apple's sign-in page would open in Safari, away from this web view's session;
        // the app signs in with Apple's own sheet instead. Not on the Mac, where the
        // page opens in this web view and comes back to the same cookie jar.
        if isMainFrame && AppleSignIn.isSignInLink(navigationAction, site: tab.rootURL) {
            Task { await AppleSignIn.signIn(in: webView, next: Self.next(from: url)) }
            return .cancel
        }
        #endif
        // Google's, which Google refuses in a web view at all, on either platform: it
        // signs in in a browser of the system's instead (GoogleSignIn).
        if isMainFrame && GoogleSignIn.isSignInLink(navigationAction, site: tab.rootURL) {
            Task { await GoogleSignIn.signIn(in: webView, next: Self.next(from: url)) }
            return .cancel
        }
        if isMainFrame && isPainting {
            let leave = await mayLeave()
            if !leave { return .cancel }
        }
        if isMainFrame {
            requestedURL = url
            restored = navigationAction.navigationType == .backForward ? .arriving : .none
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageFinished()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        endRefreshing()
        if Self.isUnreachable(error) {
            pageUnreachable()
        }
        Logger.warning("WebTab \(tab.rawValue): Failed to load - \(error.localizedDescription)", category: Logger.network)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
