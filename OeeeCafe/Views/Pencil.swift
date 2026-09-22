#if os(iOS)
import UIKit
import WebKit

/// A double-tap or a squeeze does in the painter what the reader chose for it in Settings
/// (Apple Pencil): switch to the eraser and back, or to the tool before. What the painter
/// has no counterpart for -- a colour palette, ink attributes -- it leaves alone. The
/// interaction is on only while the page is the painter (`showPageState`).
extension WebTabController: UIPencilInteractionDelegate {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        perform(UIPencilInteraction.preferredTapAction)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        perform(UIPencilInteraction.preferredSqueezeAction)
    }

    private func perform(_ action: UIPencilPreferredAction) {
        let command: String
        switch action {
        case .switchEraser: command = "toggle-eraser"
        case .switchPrevious: command = "previous-tool"
        default: return
        }
        webView.evaluateJavaScript(Scripts.painterCommand(command))
    }
}
#endif
