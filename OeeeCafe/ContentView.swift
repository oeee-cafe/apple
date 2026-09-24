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
    /// The app's one web view. The site's own toolbar is the only way around it, as it is in
    /// the Mac app.
    @StateObject private var web = WebTabController()
    @StateObject private var navigationCoordinator = NavigationCoordinator.shared

    var body: some View {
        WebTabContent(controller: web)
            .task {
                openPendingNavigation()
                web.start()
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

    private func openPendingNavigation() {
        guard let pending = navigationCoordinator.pendingNavigation else { return }
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
}
#endif
