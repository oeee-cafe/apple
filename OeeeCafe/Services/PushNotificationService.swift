import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Registers this device's push token for whoever is signed in.
///
/// Unregistering is the site's: its sign-out deletes the device named by the `oeee_device`
/// cookie (WebSession), which is set here once the device is registered.
final class PushNotificationService {
    static let shared = PushNotificationService()

    private init() {}

    /// Asks for permission the first time, then for this device's token, which APNs hands
    /// to the app delegate (`registerDeviceToken`). Called on signing in.
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

    /// Registers the token APNs gave for the signed-in user, and names it to the site's
    /// sign-out.
    func registerDeviceToken(_ deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Logger.debug("Received device token: \(token)", category: Logger.app)
        do {
            // The Mac app shares the iOS app's bundle ID, so the server's APNs topic reaches it too.
            try await APIClient.shared.post(
                path: "/api/v1/devices",
                body: RegisterDeviceRequest(deviceToken: token, platform: "ios")
            )
            await WebSession.shared.setDeviceCookie(token)
            Logger.info("Registered device with backend", category: Logger.app)
        } catch {
            Logger.error("Failed to register device with backend", error: error, category: Logger.app)
        }
    }
}

private struct RegisterDeviceRequest: Encodable {
    let deviceToken: String
    let platform: String
}
