import WebKit
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app's own question before a drawing is left, shown over the web view's window --
/// the one question the site cannot ask itself, since it is asked as the page goes. The
/// site asks everything else in its own dialog (confirm_dialog.jinja in oeee-cafe/web),
/// and calls neither alert() nor confirm(), so WKWebView is given no way to show them.
///
/// What it says is in the page's language, as the page last said it (SiteWords). Staying is
/// the default, so a reflexive Return keeps the drawing; and with nowhere to ask, the
/// drawing stays too.
enum LeaveDialog {
    #if os(macOS)
    /// Whether the reader means to leave: a sheet on the web view's window, or on whichever
    /// of the app's is in front; with no window at all, a panel of its own, which always has
    /// somewhere to be.
    static func ask(in webView: WKWebView) async -> Bool {
        let words = SiteWords.current
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = words.leaveTitle
        alert.informativeText = words.leaveBody
        // In the order a Mac lays them out, the first taking Return.
        alert.addButton(withTitle: words.stay)
        alert.addButton(withTitle: words.leave).hasDestructiveAction = true
        let response: NSApplication.ModalResponse
        if let window = webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertSecondButtonReturn
    }
    #else
    /// Whether the reader means to leave: an alert over whatever is in front in the web
    /// view's window, or when the web view is not in one yet, in the app's window in front.
    static func ask(in webView: WKWebView) async -> Bool {
        guard let presenter = webView.presenter else {
            Logger.app.warning("LeaveDialog: No window to show a dialog in")
            return false
        }
        let words = SiteWords.current
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: words.leaveTitle, message: words.leaveBody, preferredStyle: .alert)
            let stay = UIAlertAction(title: words.stay, style: .cancel) { _ in
                continuation.resume(returning: false)
            }
            alert.addAction(stay)
            alert.addAction(UIAlertAction(title: words.leave, style: .destructive) { _ in
                continuation.resume(returning: true)
            })
            alert.preferredAction = stay
            presenter.present(alert, animated: true)
        }
    }
    #endif
}

#if os(iOS)
extension WKWebView {
    /// What to present over: the front of the web view's window, or of the app's window in
    /// front when the web view is not in one.
    var presenter: UIViewController? {
        let window = window ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { ($0.activationState == .foregroundActive ? 0 : 1) < ($1.activationState == .foregroundActive ? 0 : 1) }
            .lazy
            .compactMap { $0.keyWindow ?? $0.windows.first }
            .first
        guard var presenter = window?.rootViewController else { return nil }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }
}
#endif
