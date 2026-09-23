import Foundation
import WebKit

/// What the app runs in the site's pages: the scripts it injects or evaluates, bundled as
/// the .js files beside this one so they read as JavaScript, and the few one-line calls the
/// app makes into the page -- all of them on window.oeeeApp (app_bridge.jinja in
/// oeee-cafe/web), and --oeee-text-scale.
///
/// What the site tells the app is not here: it says that itself (SiteBridge).
enum Scripts {
    /// Whether the page's `beforeunload` handlers would stop a browser, asked the way a
    /// browser asks them (`oeeeApp.wouldLoseWork`, app_bridge.jinja in oeee-cafe/web):
    /// WKWebView asks none of them, so a drawing would go without a word. Evaluated in the
    /// page's world, where the site's globals are; the answer is the expression's value.
    /// A page that is not the site's has nothing to lose.
    static let wouldLoseWork = "window.oeeeApp ? window.oeeeApp.wouldLoseWork() : false"

    #if os(iOS)
    /// HoldScale.js: keeps the painter's page at its own scale.
    static let holdScale = bundled("HoldScale")
    #endif

    #if os(macOS)
    /// ScrollToTop.js: scrolls whichever of the page and `main` is scrolled back up.
    static let scrollToTop = bundled("ScrollToTop")
    /// MacWindow.js: the window's chrome, on every page from its start.
    static let macWindow = bundled("MacWindow")
    /// QuietContextMenu.js: keeps WebKit's browser menu to where it is useful.
    static let quietContextMenu = bundled("QuietContextMenu")
    #endif

    /// Says this build can sell the Supporter Pack, before the page paints, so
    /// the buy buttons on /supporter are never drawn where nothing could
    /// answer them and never flash in after the fact (style.css in
    /// oeee-cafe/web). The Steam app says the same thing about itself with
    /// data-steam-app.
    ///
    /// Both platforms say it: the Mac app is sandboxed and sold through the
    /// Mac App Store, under the same bundle id and so with the same pack in it.
    static let markStore = "document.documentElement.setAttribute('data-store', 'apple');"

    /// Takes down the skeleton the site slid in for a page that is not coming
    /// (toolbar.jinja in oeee-cafe/web), so the page that was left shows again.
    static let restoreContent = "window.oeeeApp && window.oeeeApp.restoreContent && window.oeeeApp.restoreContent();"

    /// Fingers pan and pinch in the painter; the pen draws (frontend/shared/appBridge.ts).
    static let preferPen = "window.oeeeApp && window.oeeeApp.painter && window.oeeeApp.painter.preferPen();"

    /// One of the painter's commands ("toggle-eraser", "previous-tool").
    static func painterCommand(_ name: String) -> String {
        "window.oeeeApp && window.oeeeApp.painter && window.oeeeApp.painter.command(\(literal(name)));"
    }

    /// One of the site's commands (toolbar.jinja), which the site alone knows how to carry
    /// out. A page without the toolbar -- a replay -- has none, and the command does nothing.
    static func siteCommand(_ name: String) -> String {
        "window.oeeeApp && window.oeeeApp.command && window.oeeeApp.command(\(literal(name)));"
    }

    /// The reader's text size, for the site's type scale to follow (ds.css).
    static func textScale(_ scale: Double) -> String {
        "document.documentElement.style.setProperty('--oeee-text-scale', '\(scale)');"
    }

    /// `string` as a JavaScript string literal.
    static func literal(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    /// A script at the start of every page of the main frame.
    static func atDocumentStart(_ source: String) -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// The contents of `name`.js in the app's bundle. A missing one is a broken build, not
    /// something to go on without in silence.
    private static func bundled(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("\(name).js is not in the app's bundle")
            Logger.error("Scripts: \(name).js is not in the app's bundle")
            return ""
        }
        return source
    }
}
