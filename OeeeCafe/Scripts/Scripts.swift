import Foundation

/// The few one-line calls the app makes into the site's pages, all of them on
/// window.oeeeApp (app_bridge.jinja in oeee-cafe/web). The app injects nothing: what a page
/// needs from the platform -- its window's chrome, its scale, the reader's text size -- the
/// page asks for or finds out itself.
///
/// What the site tells the app is not here: it says that itself (SiteBridge).
enum Scripts {
    /// Whether the page's `beforeunload` handlers would stop a browser, asked the way a
    /// browser asks them (`oeeeApp.wouldLoseWork`, app_bridge.jinja in oeee-cafe/web):
    /// WKWebView asks none of them, so a drawing would go without a word. Evaluated in the
    /// page's world, where the site's globals are; the answer is the expression's value.
    /// A page that is not the site's has nothing to lose. Word for word the contract's
    /// `scripts.wouldLoseWork` (appContract.json in oeee-cafe/web), which every app asks
    /// the same way.
    static let wouldLoseWork =
        "window.oeeeApp && window.oeeeApp.wouldLoseWork ? window.oeeeApp.wouldLoseWork() : false"

    /// For a page the reader has just agreed to leave: the page puts its loading bar up
    /// (`oeeeApp.leaving`), which it does not do at the press for a load it asks about --
    /// only the app hears the answer, and a bar put up before a Stay would hang there. The
    /// promise it returns settles once the bar has had a frame to be painted in, or soon
    /// after when there is no frame to wait for, and the load begins then: WebKit stops
    /// painting the page once it does. The expression is the contract's `scripts.leaving`,
    /// word for word (`leavingExpression`); the whole is run with `callAsyncJavaScript`,
    /// for the await.
    static let leaving = "await (\(leavingExpression));"
    static let leavingExpression =
        "window.oeeeApp && window.oeeeApp.leaving ? window.oeeeApp.leaving() : null"

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

    /// `string` as a JavaScript string literal.
    static func literal(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
