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
    /// The app's one web view. The tab bar picks the section it shows; it says which
    /// section that turned out to be, and the bar draws that one (WebTabController).
    @StateObject private var web = WebTabController()
    @StateObject private var unread = UnreadCount.shared
    @StateObject private var navigationCoordinator = NavigationCoordinator.shared
    @State private var isReady = false

    private var visibleTabs: [WebTab] {
        WebTab.visible(isAuthenticated: authService.isAuthenticated)
    }

    /// The tab the reader is in: the section of the page showing, or home for a page whose
    /// section has no tab of theirs. Picking the tab they are in takes them back to its top.
    private var selection: Binding<WebTab> {
        Binding(
            get: { visibleTabs.contains(web.section) ? web.section : .home },
            set: { tab in
                if tab == web.section {
                    web.reselect()
                } else {
                    web.show(tab)
                }
            }
        )
    }

    var body: some View {
        Group {
            if isReady {
                // Declared one by one rather than with ForEach: when the tabs change on
                // signing in, a ForEach-built search tab loses its search role.
                TabView(selection: selection) {
                    webTab(.home)
                    webTab(.communities)
                    if authService.isAuthenticated {
                        webTab(.notifications)
                    } else {
                        webTab(.login)
                    }
                    Tab(WebTab.search.title, systemImage: WebTab.search.systemImage, value: WebTab.search, role: .search) {
                        SearchTabView(controller: web, isSelected: web.section == .search)
                    }
                }
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

    private func webTab(_ tab: WebTab) -> some TabContent<WebTab> {
        Tab(tab.title, systemImage: tab.systemImage, value: tab) {
            WebTabContent(controller: web)
        }
        .badge(tab == .notifications ? unread.count : 0)
    }

    private func authenticationChanged(_ isAuthenticated: Bool) async {
        if isAuthenticated {
            // Registers this device's push token for the signed-in user (asking for
            // permission the first time).
            await PushNotificationService.shared.requestPermissionsAndRegister()
        } else {
            unread.clear()
        }
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

/// A tab's page. The painter has the whole screen, as a drawing app has: no tab bar or
/// status bar, and a swipe in from an edge draws before it goes home.
struct WebTabContent: View {
    @ObservedObject var controller: WebTabController

    var body: some View {
        let painting = controller.isPainting
        WebTabView(controller: controller)
            .ignoresSafeArea(.container)
            .unreachable(controller)
            .toolbar(painting ? .hidden : .automatic, for: .tabBar)
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
