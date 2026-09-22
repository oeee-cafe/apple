import Foundation
import WebKit

/// What the app runs in the site's pages: the scripts it injects or evaluates, bundled as
/// the .js files beside this one so they read as JavaScript, and the few one-line calls the
/// app makes into the page (window.oeeeCommand, window.oeeePainter, --oeee-text-scale and
/// window.oeeeRestoreContent, all in oeee-cafe/web).
///
/// What the site tells the app is not here: it says that itself (SiteBridge).
enum Scripts {
    /// WouldLoseWork.js: whether the page's `beforeunload` handlers would stop a browser.
    static let wouldLoseWork = bundled("WouldLoseWork")

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

    /// Takes down the skeleton the site slid in for a page that is not coming
    /// (toolbar.jinja in oeee-cafe/web), so the page that was left shows again.
    static let restoreContent = "window.oeeeRestoreContent && window.oeeeRestoreContent();"

    /// Fingers pan and pinch in the painter; the pen draws (frontend/painter/iosApp.ts).
    static let preferPen = "window.oeeePainter && window.oeeePainter.preferPen();"

    /// One of the painter's commands ("toggle-eraser", "previous-tool").
    static func painterCommand(_ name: String) -> String {
        "window.oeeePainter && window.oeeePainter.command(\(literal(name)));"
    }

    /// One of the site's commands (toolbar.jinja), or `fallback` when the page has no
    /// toolbar to carry it out.
    static func siteCommand(_ name: String, fallback: URL?) -> String {
        let otherwise = fallback.map { "location.href = \(literal($0.absoluteString));" } ?? ""
        return "if (!(window.oeeeCommand && window.oeeeCommand(\(literal(name))))) { \(otherwise) }"
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
