import Foundation
import Combine
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// This device's push token, kept for the pages to register.
///
/// The app only asks for the token; registering it is the site's. A page that says someone
/// is signed in is handed it (`window.oeeeApp.pushToken`, app_bridge.jinja in
/// oeee-cafe/web), and posts it to the site from its own session, naming the platform from
/// the user agent -- so the app makes no request to the site of its own, and never has to
/// borrow the web views' cookies to make one. The site's answer sets the `oeee_device`
/// cookie that its sign-out reads to delete the device, so a device signed out gets no more
/// of that account's notifications.
final class PushNotificationService {
    static let shared = PushNotificationService()

    /// The token APNs gave last, in hex, or nil before it has given one. Kept for as long
    /// as the app runs, since every page after a sign-in is to be handed it; a page asked
    /// twice for the same token does nothing the second time.
    @Published private(set) var token: String?

    private init() {}

    /// Asks for permission the first time, then for this device's token, which APNs hands
    /// to the app delegate (`received`). Called on signing in.
    func requestPermissionsAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                Logger.info("Push notification permission denied", category: Logger.app)
                return
            }
            PlatformApplication.shared.registerForRemoteNotifications()
        } catch {
            Logger.error("Failed to request notification permissions", error: error, category: Logger.app)
        }
    }

    /// The token APNs gave, which the page showing is handed at once (WebTabController).
    func received(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Logger.debug("Received device token: \(token)", category: Logger.app)
        self.token = token
    }
}
