//
//  OeeeCafeApp.swift
//  OeeeCafe
//
//  Created by Jihyeok Seo on 10/29/25.
//

import SwiftUI
import Sentry

import UserNotifications
import os

@main
struct OeeeCafeApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        // One window onto the site, as oeee-cafe/desktop is (SiteView.swift).
        Window("Oeee Cafe", id: "main") {
            SiteView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
        .commands { SiteCommands() }
        #else
        WindowGroup {
            ContentView()
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

    /// "Open in Oeee Cafe", in Safari's address bar, and any other oeee.cafe link followed
    /// on the Mac (applinks, OeeeCafe-macOS.entitlements). The Mac hands a universal link
    /// to the application as an activity to carry on rather than as a URL to open, so
    /// SwiftUI's `onOpenURL` never hears one here, and the page the reader was on would be
    /// lost: the app would open at home. (The iPhone app is given the URL itself.)
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL
        else { return false }
        navigationCoordinator.open(url)
        return true
    }

    /// ⌘Q, the Dock and logging out all ask here first: a page holding an unsaved drawing
    /// is asked before it is left, and the app quits unless the reader chooses to stay.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            sender.reply(toApplicationShouldTerminate: await Site.shared.controller.askToLeave() != .stay)
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
            // No IP addresses or other personal data with the reports: a crash is about
            // the app, not about who was using it.
            options.sendDefaultPii = false
            options.tracesSampleRate = 1.0
            options.configureProfiling = {
                $0.sessionSampleRate = 1.0
                $0.lifecycle = .trace
            }
            // No screenshots or view hierarchies either: the screen is the site, and
            // what it shows is someone's drawings, private communities included.
            #if os(iOS)
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            #endif
            options.experimental.enableLogs = true
        }

        // Set notification delegate
        UNUserNotificationCenter.current().delegate = self

        MainActor.assumeIsolated {
            SupporterPack.listenForUpdates()
        }
    }

    // Called when APNs successfully registers the device
    func application(
        _ application: PlatformApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        pushService.received(deviceToken)
    }

    // Called when APNs registration fails
    func application(
        _ application: PlatformApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Logger.app.error("Failed to register for remote notifications: \(error.localizedDescription, privacy: .public)")
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

        Logger.app.info("User tapped notification, handling deep link navigation")

        // Handle notification tap and navigate to the appropriate screen
        navigationCoordinator.handleNotificationTap(userInfo: userInfo)

        completionHandler()
    }
}
