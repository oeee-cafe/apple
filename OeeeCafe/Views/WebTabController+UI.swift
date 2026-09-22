import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// WebKit asking the app for what a browser would give a page itself: new windows, the
/// page's own dialogs, menus and file pickers.
extension WebTabController: WKUIDelegate {
    /// Links that ask for a new window open in this tab, or outside the app for other sites.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isSiteURL(url) {
                webView.load(navigationAction.request)
            } else {
                openOutside(url)
            }
        }
        return nil
    }

    // WKWebView shows none of alert(), confirm() or prompt() by itself: without these,
    // alert() does nothing and confirm() answers "cancel", which htmx takes as "no".

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        await JavaScriptDialog.alert(message, in: webView)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await JavaScriptDialog.confirm(message, in: webView)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        await JavaScriptDialog.prompt(prompt, defaultText: defaultText ?? "", in: webView)
    }

    #if os(iOS)
    /// A long press on a drawing: the app's own menu for it (DrawingMenu). Anywhere else the
    /// site lets a press through -- text fields, what people wrote -- WebKit's own.
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        guard let drawing = pressedDrawing else {
            completionHandler(nil)
            return
        }
        completionHandler(DrawingMenu.configuration(for: drawing, in: webView))
    }

    /// Tapping the preview opens the drawing's post, as tapping the drawing would have.
    func webView(
        _ webView: WKWebView,
        contextMenuForElement elementInfo: WKContextMenuElementInfo,
        willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let link = pressedDrawing?.link ?? elementInfo.linkURL else { return }
        animator.addCompletion { [weak self] in
            self?.load(link)
        }
    }
    #endif

    #if os(macOS)
    /// `<input type="file">`: iOS shows its own picker, macOS asks the app.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        guard let window = webView.window else {
            return panel.runModal() == .OK ? panel.urls : nil
        }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }
    #endif
}
