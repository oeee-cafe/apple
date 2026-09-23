#if os(macOS)
import AppKit

/// The number on the site's bell: unread notifications and invitations waiting, together,
/// as the page says it (`unread`, SiteBridge). The Mac's Dock icon wears it. The iPhone app
/// has no use for it: its icon's badge is the push notifications'.
///
/// The site says it whenever the bell changes, so it is not asked for.
enum UnreadCount {
    private static var count = 0

    static func set(_ count: Int) {
        let count = max(count, 0)
        guard count != self.count else { return }
        self.count = count
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    /// Signed out, there is no bell to say anything.
    static func clear() {
        set(0)
    }
}
#endif
