import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

/// The number on the site's bell: unread notifications and invitations waiting, together,
/// as the page says it (`unread`, SiteBridge). The iOS notifications tab wears it, and the
/// Mac's Dock icon.
///
/// The site says it whenever the bell changes, so it is not asked for: before the bridge,
/// iOS asked the API after every page and the Mac read the bell's markup, which stopped
/// matching the day the bell changed.
final class UnreadCount: ObservableObject {
    static let shared = UnreadCount()

    @Published private(set) var count = 0

    private init() {}

    func set(_ count: Int) {
        let count = max(count, 0)
        guard count != self.count else { return }
        self.count = count
        #if os(macOS)
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        #endif
    }

    /// Signed out, there is no bell to say anything.
    func clear() {
        set(0)
    }
}
