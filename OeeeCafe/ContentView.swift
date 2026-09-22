//
//  ContentView.swift
//  OeeeCafe
//
//  Created by Jihyeok Seo on 10/29/25.
//

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
                TabView(selection: selection) {
                    ForEach(visibleTabs, id: \.self) { tab in
                        Tab(tab.title, systemImage: tab.systemImage, value: tab, role: tab == .search ? .search : nil) {
                            tabContent(tab)
                        }
                        .badge(badges.count(for: tab))
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    @ViewBuilder
    private func tabContent(_ tab: WebTab) -> some View {
        if tab == .search {
            SearchTabView(controller: webTabs.controller(for: tab))
        } else {
            WebTabView(controller: webTabs.controller(for: tab))
                .ignoresSafeArea(.container)
        }
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

/// Counts shown on the tab bar, read from the API as the signed-in user.
final class BadgeCounts: ObservableObject {
    @Published private var unreadNotifications = 0
    @Published private var invitations = 0
    @Published private var drafts = 0

    func count(for tab: WebTab) -> Int {
        switch tab {
        case .notifications: return unreadNotifications + invitations
        case .drafts: return drafts
        default: return 0
        }
    }

    func refresh() async {
        let api = APIClient.shared
        async let unread: UnreadCount? = try? api.fetch(path: "/api/v1/notifications/unread-count")
        async let invitations: Invitations? = try? api.fetch(path: "/api/v1/invitations")
        async let drafts: Drafts? = try? api.fetch(path: "/api/v1/posts/drafts")
        if let unread = await unread { self.unreadNotifications = unread.count }
        if let invitations = await invitations { self.invitations = invitations.invitations.count }
        if let drafts = await drafts { self.drafts = drafts.drafts.count }
    }

    func clear() {
        unreadNotifications = 0
        invitations = 0
        drafts = 0
    }

    private struct Item: Decodable {}
    private struct UnreadCount: Decodable { let count: Int }
    private struct Invitations: Decodable { let invitations: [Item] }
    private struct Drafts: Decodable { let drafts: [Item] }
}

#Preview {
    ContentView()
        .environmentObject(AuthService.shared)
}
