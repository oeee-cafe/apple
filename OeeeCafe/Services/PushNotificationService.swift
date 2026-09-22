import Foundation
import UserNotifications
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Service for managing push notification registration and token handling
class PushNotificationService: ObservableObject {
    static let shared = PushNotificationService()

    @Published var permissionStatus: UNAuthorizationStatus = .notDetermined
    @Published var showPermissionDeniedMessage = false

    private let apiClient = APIClient.shared
    private let keychainHelper = KeychainHelper.shared
    private var currentDeviceToken: String?
    private let deviceTokenKeychainKey = "deviceToken"

    private init() {
        checkPermissionStatus()
    }

    // MARK: - Public Methods

    /// Request notification permissions and register for push notifications
    /// This should be called after successful login
    func requestPermissionsAndRegister() async {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])

            await MainActor.run {
                self.permissionStatus = granted ? .authorized : .denied

                if !granted {
                    // Show message to user about denied permissions
                    self.showPermissionDeniedMessage = true
                    Logger.info("Push notification permission denied", category: Logger.app)
                } else {
                    Logger.info("Push notification permission granted", category: Logger.app)
                }
            }

            if granted {
                // Register for remote notifications on the main thread
                await MainActor.run {
                    PlatformApplication.shared.registerForRemoteNotifications()
                }
            }
        } catch {
            Logger.error("Failed to request notification permissions", error: error, category: Logger.app)
            await MainActor.run {
                self.showPermissionDeniedMessage = true
            }
        }
    }

    /// Register device token with backend
    /// Called from AppDelegate when APNs returns a device token
    func registerDeviceToken(_ deviceToken: Data) async {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Logger.debug("Received device token: \(tokenString)", category: Logger.app)

        // Store the token in memory and keychain
        self.currentDeviceToken = tokenString
        if keychainHelper.saveString(key: deviceTokenKeychainKey, value: tokenString) {
            Logger.debug("Device token saved to keychain", category: Logger.app)
        } else {
            Logger.warning("Failed to save device token to keychain", category: Logger.app)
        }

        do {
            // The Mac app shares the iOS app's bundle ID, so the server's APNs topic reaches it too.
            let request = RegisterDeviceRequest(deviceToken: tokenString, platform: "ios")
            let response: RegisterDeviceResponse = try await apiClient.post(
                path: "/api/v1/devices",
                body: request
            )

            Logger.info("Successfully registered device with backend: \(response.id)", category: Logger.app)
        } catch {
            Logger.error("Failed to register device with backend", error: error, category: Logger.app)
        }
    }

    /// Get the current device token
    /// Retrieves from memory first, falls back to keychain if not in memory
    func getDeviceToken() -> String? {
        // Return memory value if available
        if let token = currentDeviceToken {
            return token
        }

        // Fallback to keychain
        if let token = keychainHelper.loadString(key: deviceTokenKeychainKey) {
            Logger.debug("Device token retrieved from keychain", category: Logger.app)
            // Update memory cache
            self.currentDeviceToken = token
            return token
        }

        Logger.debug("No device token found in memory or keychain", category: Logger.app)
        return nil
    }

    /// Delete device from backend
    /// This should be called during logout
    func deleteDevice() async {
        // Try to get token from memory or keychain
        guard let token = getDeviceToken() else {
            Logger.warning("No device token found to delete (checked both memory and keychain)", category: Logger.app)
            return
        }

        Logger.debug("Attempting to delete device: \(token)", category: Logger.app)

        do {
            try await apiClient.delete(
                path: "/api/v1/devices/\(token)"
            )

            Logger.info("Successfully deleted device from backend", category: Logger.app)

            // Clear the stored token from both memory and keychain after successful deletion
            self.currentDeviceToken = nil
            if keychainHelper.delete(key: deviceTokenKeychainKey) {
                Logger.debug("Device token deleted from keychain", category: Logger.app)
            } else {
                Logger.warning("Failed to delete device token from keychain", category: Logger.app)
            }
        } catch {
            Logger.error("Failed to delete device from backend", error: error, category: Logger.app)
        }
    }

    // MARK: - Private Methods

    private func checkPermissionStatus() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            await MainActor.run {
                self.permissionStatus = settings.authorizationStatus
            }
        }
    }
}

// MARK: - Supporting Types

struct RegisterDeviceRequest: Encodable {
    let deviceToken: String
    let platform: String
}

struct RegisterDeviceResponse: Decodable {
    let id: String
    let deviceToken: String
    let platform: String
    let createdAt: Date
}
