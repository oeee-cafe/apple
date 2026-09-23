//
//  ContentView.swift
//  OeeeCafe
//
//  Created by Jihyeok Seo on 10/29/25.
//

// The iPhone and iPad app. The Mac app is one window onto the site instead (SiteView.swift).
#if os(iOS)
import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject var authService: AuthService
    /// The app's one web view. The site's own toolbar is the only way around it, as it is in
    /// the Mac app.
    @StateObject private var web = WebTabController()
    @StateObject private var navigationCoordinator = NavigationCoordinator.shared
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                WebTabContent(controller: web)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color("Ground"))
            }
        }
        .task {
            // Carries over a session signed in natively before anything is fetched.
            await WebSession.shared.start()
            web.start()
            isReady = true
            // Before asking about notifications: a page waiting to be opened is what the
            // reader came for, and does not wait behind a permission they may sit on.
            openPendingNavigation()
            await authenticationChanged(authService.isAuthenticated)
        }
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            guard isReady else { return }
            web.authenticationChanged(signedIn: isAuthenticated)
            Task { await authenticationChanged(isAuthenticated) }
        }
        .onChange(of: navigationCoordinator.pendingNavigation) { _, _ in
            openPendingNavigation()
        }
        // A tapped oeee.cafe link, from another app (applinks, OeeeCafe.entitlements).
        .onOpenURL { url in
            navigationCoordinator.open(url)
        }
        .background(SiteThemeApplier())
    }

    private func authenticationChanged(_ isAuthenticated: Bool) async {
        guard isAuthenticated else { return }
        // Asks for this device's push token (and for permission, the first time),
        // which the pages then register for whoever is signed in.
        await PushNotificationService.shared.requestPermissionsAndRegister()
    }

    private func openPendingNavigation() {
        guard isReady, let pending = navigationCoordinator.pendingNavigation else { return }
        navigationCoordinator.clearPendingNavigation()
        guard let url = pending.url else { return }
        web.load(url)
    }
}

/// Puts the site's light/dark choice on the window as soon as there is one, before any page
/// has said it again.
private struct SiteThemeApplier: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Applier() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Applier: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                SiteTheme.shared.apply(to: window)
            }
        }
    }
}

/// The page. The painter has the whole screen, as a drawing app has: no status bar, and a
/// swipe in from an edge draws before it goes home.
struct WebTabContent: View {
    @ObservedObject var controller: WebTabController

    var body: some View {
        let painting = controller.isPainting
        WebTabView(controller: controller)
            .ignoresSafeArea(.container)
            .unreachable(controller)
            .statusBarHidden(painting)
            .persistentSystemOverlays(painting ? .hidden : .automatic)
            .defersSystemGestures(on: painting ? .all : [])
            .animation(.default, value: painting)
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthService.shared)
}
#endif
