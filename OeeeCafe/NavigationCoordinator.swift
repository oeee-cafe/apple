import Foundation
import Combine

/// Coordinator for handling deep link navigation from push notifications and other sources
class NavigationCoordinator: ObservableObject {
    static let shared = NavigationCoordinator()

    /// A page to open from outside the app (a push notification), and the tab to open it in.
    @Published var pendingNavigation: PendingNavigation?

    private init() {}

    struct PendingNavigation: Equatable {
        let tab: WebTab
        let path: String

        var url: URL? {
            URL(string: APIConfig.shared.baseURL + path)
        }
    }

    private func navigate(to path: String, in tab: WebTab) {
        Logger.debug("NavigationCoordinator: Navigating to \(path) in \(tab.rawValue) tab", category: Logger.app)
        pendingNavigation = PendingNavigation(tab: tab, path: path)
    }

    /// Navigate to a post detail screen
    func navigateToPost(id: String) {
        navigate(to: "/posts/\(id)", in: .home)
    }

    /// Navigate to a user profile screen
    func navigateToProfile(loginName: String) {
        navigate(to: "/@\(loginName)", in: .home)
    }

    /// Navigate to community members screen
    func navigateToCommunityMembers(slug: String) {
        navigate(to: "/communities/@\(slug)/members", in: .communities)
    }

    /// Navigate to notifications tab, where community invitations are listed too
    func navigateToNotifications() {
        navigate(to: WebTab.notifications.path, in: .notifications)
    }

    /// Handle push notification payload and navigate to the appropriate screen
    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        Logger.debug("NavigationCoordinator: Handling notification tap with data: \(userInfo)", category: Logger.app)

        guard let notificationType = userInfo["notification_type"] as? String else {
            Logger.warning("NavigationCoordinator: No notification_type found in payload", category: Logger.app)
            return
        }

        Logger.info("NavigationCoordinator: Processing notification type: \(notificationType)", category: Logger.app)

        switch notificationType {
        case "Comment", "Mention", "CommentReply", "PostReply", "CommunityPost", "Reaction":
            // Navigate to post detail
            if let postId = userInfo["post_id"] as? String {
                navigateToPost(id: postId)
            } else {
                Logger.warning("NavigationCoordinator: Missing post_id for \(notificationType)", category: Logger.app)
            }

        case "Follow":
            // Navigate to actor's profile
            if let actorLoginName = userInfo["actor_login_name"] as? String {
                navigateToProfile(loginName: actorLoginName)
            } else {
                Logger.warning("NavigationCoordinator: Missing actor_login_name for Follow", category: Logger.app)
            }

        case "GuestbookEntry", "GuestbookReply":
            // Navigate to actor's profile (guestbook tab)
            if let actorLoginName = userInfo["actor_login_name"] as? String {
                navigateToProfile(loginName: actorLoginName)
            } else {
                Logger.warning("NavigationCoordinator: Missing actor_login_name for \(notificationType)", category: Logger.app)
            }

        case "community_invite":
            // Invitations are listed on the notifications page
            navigateToNotifications()

        case "invitation_accepted", "invitation_declined":
            // Navigate to community members screen
            if let communitySlug = userInfo["community_slug"] as? String {
                navigateToCommunityMembers(slug: communitySlug)
            } else {
                Logger.warning("NavigationCoordinator: Missing community_slug for \(notificationType)", category: Logger.app)
            }

        default:
            Logger.warning("NavigationCoordinator: Unknown notification type: \(notificationType)", category: Logger.app)
            // Fallback: Navigate to notifications tab
            navigateToNotifications()
        }
    }

    /// Clear pending navigation after it has been processed
    func clearPendingNavigation() {
        pendingNavigation = nil
    }
}
