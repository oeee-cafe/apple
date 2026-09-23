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
    @StateObject private var webTabs = WebTabStore()
    @StateObject private var unread = UnreadCount.shared
    @StateObject private var navigationCoordinator = NavigationCoordinator.shared
    @State private var isReady = false
    @State private var tabSelection: WebTab = .home

    private var visibleTabs: [WebTab] {
        WebTab.visible(isAuthenticated: authService.isAuthenticated)
    }

    /// Selecting the already selected tab takes it back to its top.
    private var selection: Binding<WebTab> {
        Binding(
            get: { tabSelection },
            set: { tab in
                if tab == tabSelection {
                    webTabs.controller(for: tab).reselect()
                }
                tabSelection = tab
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
                        SearchTabView(
                            controller: webTabs.controller(for: .search),
                            isSelected: tabSelection == .search
                        )
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color("Ground"))
            }
        }
        .task {
            // Carries over a session signed in natively before showing any tab.
            await WebSession.shared.start()
            Task { await AuthService.shared.checkOnce() }
            isReady = true
            // Before asking about notifications: a page waiting to be opened is what the
            // reader came for, and does not wait behind a permission they may sit on.
            openPendingNavigation()
            await authenticationChanged(authService.isAuthenticated)
        }
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            guard isReady else { return }
            webTabs.authenticationChanged(visibleTabs: visibleTabs, signedIn: isAuthenticated)
            if !visibleTabs.contains(tabSelection) {
                tabSelection = .home
            }
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
            WebTabContent(controller: webTabs.controller(for: tab))
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
        guard visibleTabs.contains(pending.tab), let url = pending.url else { return }
        tabSelection = pending.tab
        let controller = webTabs.controller(for: pending.tab)
        if pending.fresh {
            controller.load(url)
        } else {
            controller.show(url)
        }
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
