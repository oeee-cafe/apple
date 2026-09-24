#if os(macOS)
import AppKit

/// The number on the site's bell: unread notifications and invitations waiting, together,
/// as the page says it (`unread`, SiteBridge). The Mac's Dock icon wears it. The iPhone app
/// has no use for it: its icon's badge is the push notifications'.
///
/// The site says it whenever the bell changes, so it is not asked for.
enum UnreadCount {
    static func set(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
}
#endif
