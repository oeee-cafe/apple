import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A page's alert(), confirm() and prompt(), and the app's own question before a drawing is
/// left, shown over the web view's window.
///
/// Each is described once, the same on both platforms; only putting it on screen differs.
enum JavaScriptDialog {
    static func alert(_ message: String, in webView: WKWebView) async {
        _ = await show(Dialog(message: message, actions: [.ok]), in: webView)
    }

    static func confirm(_ message: String, in webView: WKWebView) async -> Bool {
        await show(Dialog(message: message, actions: [.ok, .cancel]), in: webView)?.action == 0
    }

    /// The text entered, or nil when cancelled.
    static func prompt(_ message: String, defaultText: String, in webView: WKWebView) async -> String? {
        let answer = await show(Dialog(message: message, actions: [.ok, .cancel], field: defaultText), in: webView)
        return answer?.action == 0 ? answer?.text ?? "" : nil
    }

    /// Whether the reader means to leave a page that holds something unsaved. Staying is
    /// the default, so a reflexive Return keeps the drawing; and with nowhere to ask, the
    /// drawing stays too.
    static func confirmLeaving(in webView: WKWebView) async -> Bool {
        let dialog = Dialog(
            title: "leave.title".localized,
            message: "leave.body".localized,
            actions: [
                Action(title: "leave.stay".localized, role: .cancel),
                Action(title: "leave.leave".localized, role: .destructive),
            ],
            isWarning: true,
            prefersFirst: true
        )
        return await show(dialog, in: webView)?.action == 1
    }

    // MARK: - The dialog

    struct Action {
        enum Role { case normal, cancel, destructive }
        let title: String
        let role: Role

        static var ok: Action { Action(title: "common.ok".localized, role: .normal) }
        static var cancel: Action { Action(title: "common.cancel".localized, role: .cancel) }
    }

    struct Dialog {
        var title: String?
        var message: String
        /// In the order a Mac lays them out, the first taking Return.
        var actions: [Action]
        /// A prompt's text field, with the text it starts with.
        var field: String?
        var isWarning = false
        /// Whether the first action is the one to lean on on iOS too, where it would
        /// otherwise sit wherever its role puts it.
        var prefersFirst = false

        init(title: String? = nil, message: String, actions: [Action], field: String? = nil, isWarning: Bool = false, prefersFirst: Bool = false) {
            self.title = title
            self.message = message
            self.actions = actions
            self.field = field
            self.isWarning = isWarning
            self.prefersFirst = prefersFirst
        }
    }

    /// Which action was chosen, and what the text field held.
    struct Answer {
        let action: Int
        let text: String
    }

    // MARK: - Showing it

    #if os(macOS)
    /// As a sheet on the web view's window, or on whichever of the app's is in front; with
    /// no window at all, as a panel of its own, which always has somewhere to be.
    static func show(_ dialog: Dialog, in webView: WKWebView) async -> Answer? {
        let alert = NSAlert()
        alert.alertStyle = dialog.isWarning ? .warning : .informational
        if let title = dialog.title {
            alert.messageText = title
            alert.informativeText = dialog.message
        } else {
            alert.messageText = dialog.message
        }
        for action in dialog.actions {
            let button = alert.addButton(withTitle: action.title)
            button.hasDestructiveAction = action.role == .destructive
        }
        var field: NSTextField?
        if let text = dialog.field {
            let textField = NSTextField(string: text)
            textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = textField
            alert.window.initialFirstResponder = textField
            field = textField
        }
        let response: NSApplication.ModalResponse
        if let window = webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard dialog.actions.indices.contains(index) else { return nil }
        return Answer(action: index, text: field?.stringValue ?? "")
    }
    #else
    /// Over whatever is in front in the web view's window, or when the web view is not in
    /// one -- a tab not on screen yet -- in the app's window in front. Nil when the app has
    /// no window to show it in.
    static func show(_ dialog: Dialog, in webView: WKWebView) async -> Answer? {
        guard let presenter = presenter(for: webView) else {
            Logger.warning("JavaScriptDialog: No window to show a dialog in", category: Logger.app)
            return nil
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: dialog.title, message: dialog.message, preferredStyle: .alert)
            if let text = dialog.field {
                alert.addTextField { $0.text = text }
            }
            for (index, action) in dialog.actions.enumerated() {
                let style: UIAlertAction.Style
                switch action.role {
                case .normal: style = .default
                case .cancel: style = .cancel
                case .destructive: style = .destructive
                }
                let button = UIAlertAction(title: action.title, style: style) { [weak alert] _ in
                    continuation.resume(returning: Answer(action: index, text: alert?.textFields?.first?.text ?? ""))
                }
                alert.addAction(button)
                if index == 0 && dialog.prefersFirst {
                    alert.preferredAction = button
                }
            }
            presenter.present(alert, animated: true)
        }
    }

    /// What to present over: the front of the web view's window, or of the app's window in
    /// front when the web view is not in one.
    static func presenter(for webView: WKWebView) -> UIViewController? {
        let window = webView.window ?? UIApplication.shared.connectedScenes
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
    #endif
}
