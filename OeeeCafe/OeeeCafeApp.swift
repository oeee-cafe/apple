//
//  OeeeCafeApp.swift
//  OeeeCafe
//
//  Created by Jihyeok Seo on 10/29/25.
//

import SwiftUI
import Sentry

import UserNotifications

@main
struct OeeeCafeApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @StateObject private var authService = AuthService.shared

    var body: some Scene {
        #if os(macOS)
        // One window onto the site, as oeee-cafe/desktop is (SiteView.swift).
        Window("Oeee Cafe", id: "main") {
            SiteView()
                .environmentObject(authService)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
        .commands { SiteCommands() }
        #else
        WindowGroup {
            ContentView()
                .environmentObject(authService)
        }
        #endif
    }
}

// MARK: - AppDelegate

#if os(macOS)
typealias PlatformApplication = NSApplication
typealias PlatformApplicationDelegate = NSApplicationDelegate
#else
typealias PlatformApplication = UIApplication
typealias PlatformApplicationDelegate = UIApplicationDelegate
#endif

class AppDelegate: NSObject, PlatformApplicationDelegate, UNUserNotificationCenterDelegate {
    private let pushService = PushNotificationService.shared
    private let navigationCoordinator = NavigationCoordinator.shared

    #if os(macOS)
    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching()
    }

    /// There is one window, and closing it is quitting (Site.closeWindow).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q, the Dock and logging out all ask here first: a page holding an unsaved drawing
    /// is asked before it is left.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            sender.reply(toApplicationShouldTerminate: await Site.shared.mayLeave())
        }
        return .terminateLater
    }
    #else
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        didFinishLaunching()
        return true
    }
    #endif

    private func didFinishLaunching() {
        SentrySDK.start { options in
            options.dsn = "https://cb81dc57b22c71d2c1a789a8905ea6b6@o4504757655764992.ingest.us.sentry.io/4510413260193792"

            // Adds IP for users.
            // For more information, visit: https://docs.sentry.io/platforms/apple/data-management/data-collected/
            options.sendDefaultPii = true

            // Set tracesSampleRate to 1.0 to capture 100% of transactions for performance monitoring.
            // We recommend adjusting this value in production.
            options.tracesSampleRate = 1.0

            // Configure profiling. Visit https://docs.sentry.io/platforms/apple/profiling/ to learn more.
            options.configureProfiling = {
                $0.sessionSampleRate = 1.0 // We recommend adjusting this value in production.
                $0.lifecycle = .trace
            }

            #if os(iOS)
            // Uncomment the following lines to add more data to your events
            options.attachScreenshot = true // This adds a screenshot to the error events
            options.attachViewHierarchy = true // This adds the view hierarchy to the error events
            #endif
            
            // Enable experimental logging features
            options.experimental.enableLogs = true
        }
        // Remove the next line after confirming that your Sentry integration is working.
        // SentrySDK.capture(message: "This app uses Sentry! :)")

        // Set notification delegate
        UNUserNotificationCenter.current().delegate = self
    }

    // Called when APNs successfully registers the device
    func application(
        _ application: PlatformApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            await pushService.registerDeviceToken(deviceToken)
        }
    }

    // Called when APNs registration fails
    func application(
        _ application: PlatformApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Logger.error("Failed to register for remote notifications", error: error, category: Logger.app)
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Called when a notification is received while the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }

    // Called when user taps on a notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        Logger.info("User tapped notification, handling deep link navigation", category: Logger.app)

        // Handle notification tap and navigate to the appropriate screen
        navigationCoordinator.handleNotificationTap(userInfo: userInfo)

        completionHandler()
    }
}
