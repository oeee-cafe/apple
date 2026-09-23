import SwiftUI
import Combine
import Network

/// Whether the device can reach the network at all, so a page that could not be reached is
/// tried again once it can, as the desktop app's loader does on the browser's `online`.
final class Connectivity {
    static let shared = Connectivity()

    /// Sent when the network comes back after being gone.
    let restored = PassthroughSubject<Void, Never>()

    private let monitor = NWPathMonitor()
    private var wasSatisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                if satisfied && !self.wasSatisfied {
                    self.restored.send()
                }
                self.wasSatisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "cafe.oeee.connectivity"))
    }
}

/// The page, on an iPhone or in the Mac's window, whose first page could not be reached: said in words, with a
/// way to try again, rather than the web view's own error page or nothing at all.
struct UnreachableView: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            Text("site.unreachable_title".localized)
                .font(.headline)
            Text("site.unreachable_body".localized)
                .foregroundStyle(.secondary)
            Button("site.retry".localized, action: retry)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 12)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("Ground"))
    }
}

extension View {
    /// What a page shows when the site cannot be reached: over the whole of it when there
    /// is nothing yet to show, and otherwise a moment's notice over the page it stayed on.
    func unreachable(_ controller: WebTabController) -> some View {
        modifier(UnreachableModifier(controller: controller))
    }
}

private struct UnreachableModifier: ViewModifier {
    @ObservedObject var controller: WebTabController

    func body(content: Content) -> some View {
        content
            .overlay {
                if controller.isUnreachable {
                    UnreachableView { controller.retry() }
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if controller.isMissingPage {
                    Label("site.unreachable_title".localized, systemImage: "wifi.slash")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.default, value: controller.isUnreachable)
            .animation(.spring(duration: 0.35), value: controller.isMissingPage)
    }
}
