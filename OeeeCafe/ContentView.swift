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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var webTabs = WebTabStore()
    @StateObject private var badges = BadgeCounts()
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
                        SearchTabView(controller: webTabs.controller(for: .search))
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color("Ground"))
            }
        }
        .task {
            webTabs.onPageLoad = { [badges, authService] in
                guard authService.isAuthenticated else { return }
                Task { await badges.refresh() }
            }
            // Picks up whoever is signed in on the web views before showing any tab.
            await WebSession.shared.start()
            isReady = true
            await authenticationChanged(authService.isAuthenticated)
            openPendingNavigation()
        }
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            guard isReady else { return }
            webTabs.authenticationChanged(visibleTabs: visibleTabs)
            if !visibleTabs.contains(tabSelection) {
                tabSelection = .home
            }
            Task { await authenticationChanged(isAuthenticated) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && authService.isAuthenticated {
                Task { await badges.refresh() }
            }
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
        .badge(badges.count(for: tab))
    }

    private func authenticationChanged(_ isAuthenticated: Bool) async {
        if isAuthenticated {
            // Registers this device's push token for the signed-in user (asking for
            // permission the first time).
            await PushNotificationService.shared.requestPermissionsAndRegister()
            await badges.refresh()
        } else {
            badges.clear()
        }
    }

    private func openPendingNavigation() {
        guard isReady, let pending = navigationCoordinator.pendingNavigation else { return }
        navigationCoordinator.clearPendingNavigation()
        guard visibleTabs.contains(pending.tab), let url = pending.url else { return }
        tabSelection = pending.tab
        webTabs.controller(for: pending.tab).load(url)
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
            .toolbar(painting ? .hidden : .automatic, for: .tabBar)
            .statusBarHidden(painting)
            .persistentSystemOverlays(painting ? .hidden : .automatic)
            .defersSystemGestures(on: painting ? .all : [])
            .animation(.default, value: painting)
    }
}

/// Counts shown on the tab bar, read from the API as the signed-in user.
final class BadgeCounts: ObservableObject {
    @Published private var unreadNotifications = 0
    @Published private var invitations = 0

    func count(for tab: WebTab) -> Int {
        switch tab {
        case .notifications: return unreadNotifications + invitations
        default: return 0
        }
    }

    func refresh() async {
        let api = APIClient.shared
        async let unread: UnreadCount? = try? api.fetch(path: "/api/v1/notifications/unread-count")
        async let invitations: Invitations? = try? api.fetch(path: "/api/v1/invitations")
        if let unread = await unread { self.unreadNotifications = unread.count }
        if let invitations = await invitations { self.invitations = invitations.invitations.count }
    }

    func clear() {
        unreadNotifications = 0
        invitations = 0
    }

    private struct Item: Decodable {}
    private struct UnreadCount: Decodable { let count: Int }
    private struct Invitations: Decodable { let invitations: [Item] }
}

#Preview {
    ContentView()
        .environmentObject(AuthService.shared)
}
#endif
