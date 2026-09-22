#if os(macOS)
import AppKit
typealias PlatformWindow = NSWindow
#else
import UIKit
typealias PlatformWindow = UIWindow
#endif

/// The site's light/dark choice, made the app's: a reader who picked the dark look in the
/// site's toolbar while the system is light gets a light status bar and a dark tab bar,
/// alerts and menus to go with the page, rather than the system's. Remembered, so the app
/// opens in it rather than turning over once the first page says so.
final class SiteTheme {
    static let shared = SiteTheme()

    private let key = "site_theme"

    /// "light", "dark", or nil for the system's.
    private(set) var choice: String?

    private init() {
        choice = UserDefaults.standard.string(forKey: key)
    }

    /// What a page says the reader chose (`theme.choice`, SiteBridge): "light", "dark", or
    /// "system" for the system's.
    func choose(_ theme: String?, in window: PlatformWindow?) {
        let theme = (theme == "light" || theme == "dark") ? theme : nil
        if theme != choice {
            choice = theme
            UserDefaults.standard.set(theme, forKey: key)
        }
        if let window {
            apply(to: window)
        }
    }

    func apply(to window: PlatformWindow) {
        #if os(macOS)
        switch choice {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        default: window.appearance = nil
        }
        #else
        let style: UIUserInterfaceStyle
        switch choice {
        case "light": style = .light
        case "dark": style = .dark
        default: style = .unspecified
        }
        guard window.overrideUserInterfaceStyle != style else { return }
        UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve) {
            window.overrideUserInterfaceStyle = style
        }
        #endif
    }
}
