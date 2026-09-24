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
    @StateObject private var web = WebController()

    var body: some View {
        WebContent(controller: web)
            .opensPages(in: web)
            .background(SiteThemeApplier())
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
struct WebContent: View {
    @ObservedObject var controller: WebController

    var body: some View {
        let painting = controller.isPainting
        WebContainer(controller: controller)
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
