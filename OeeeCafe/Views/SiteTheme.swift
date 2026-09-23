import Combine
#if os(macOS)
import AppKit
typealias PlatformWindow = NSWindow
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformWindow = UIWindow
typealias PlatformColor = UIColor
#endif

/// The site's light/dark choice, made the app's: a reader who picked the dark look in the
/// site's toolbar while the system is light gets a light status bar,
/// alerts and menus to go with the page, rather than the system's. Remembered, so the app
/// opens in it rather than turning over once the first page says so.
///
/// And the site's ground, for what the app paints where the page does not reach: the strip
/// behind the status bar, under an overscroll, the window behind a page still arriving. The
/// pages say it (`theme.ground`), so the app draws what the site draws rather than a copy of
/// NEO's colours kept in step by hand; the asset catalog's Ground is only for before the
/// first page has said.
final class SiteTheme: ObservableObject {
    static let shared = SiteTheme()

    private let key = "site_theme"

    /// The ground as the page last said it; nil before it has.
    struct Colours: Equatable {
        var ground: PlatformColor?
    }

    @Published private(set) var colours = Colours()

    /// The ground in `colours`, or the asset catalog's before a page has said.
    static func ground(_ colours: Colours) -> PlatformColor {
        colours.ground ?? PlatformColor(named: "Ground")!
    }

    /// The ground now.
    var ground: PlatformColor { Self.ground(colours) }

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

    /// What a page says the ground is, as a CSS colour. A page that does not say -- one
    /// without the design system -- leaves it as it was.
    func paint(ground: String?) {
        guard ground != nil else { return }
        let said = Colours(ground: Self.colour(css: ground))
        if said != colours {
            colours = said
        }
    }

    /// A CSS hex colour (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`), which is how the design
    /// system writes its tokens; nil for anything else.
    static func colour(css: String?) -> PlatformColor? {
        guard var hex = css?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 || hex.count == 4 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? value << 8 | 0xff : value
        func channel(_ shift: UInt64) -> CGFloat { CGFloat((rgba >> shift) & 0xff) / 255 }
        #if os(macOS)
        return NSColor(srgbRed: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
        #else
        return UIColor(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
        #endif
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
