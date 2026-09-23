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
    /// A page that is not the site's has nothing to lose.
    static let wouldLoseWork = "window.oeeeApp ? window.oeeeApp.wouldLoseWork() : false"

    /// The site's loading bar (loading_bar.jinja in oeee-cafe/web), for a page the reader
    /// has just agreed to leave. The page puts it up at the press for any other load, but
    /// not for one it asks about: only the app hears the answer, and a bar put up before a
    /// Stay would hang there. WebKit stops painting the page once the load begins, so the
    /// bar is shown and a frame let pass first, as the page's own `oeeeLoadingBar.leave`
    /// does -- and not waited on for longer than a moment, since a web view that is not on
    /// the screen has no frames to wait for. Run with `callAsyncJavaScript`, for the await.
    static let showLeaving = """
        if (window.oeeeLoadingBar) {
          window.oeeeLoadingBar.start(null, true);
          await new Promise(function (resolve) {
            requestAnimationFrame(function () { resolve(); });
            setTimeout(resolve, 100);
          });
        }
        """

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
