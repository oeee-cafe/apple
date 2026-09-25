#if os(macOS)
import AppKit
#else
import UserNotifications
#endif

/// The number on the site's bell: unread notifications and invitations waiting, together,
/// as the page says it (`unread`, SiteBridge). The Mac's Dock icon wears it, and so does the
/// iPhone's and iPad's app icon.
///
/// On iOS a push sets the icon's badge while the app is away, and nothing else ever took it
/// down: reading the notifications on the site left the number standing on the Home Screen
/// until the next push replaced it. The page is what knows the real count, so while it is
/// showing, the badge is its.
///
/// The site says it whenever the bell changes, so it is not asked for.
enum UnreadCount {
    static func set(_ count: Int) {
        #if os(macOS)
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        #else
        UNUserNotificationCenter.current().setBadgeCount(max(count, 0))
        #endif
    }
}
