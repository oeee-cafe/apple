import Foundation

/// Every call the app makes into the site's pages, all of them on window.oeeeApp
/// (app_bridge.jinja in oeee-cafe/web), and all of them here rather than where they are
/// made, so that the contract test (OeeeCafeTests) can check each member they reach for
/// against the site's list of them (appContract.json). The app injects nothing: what a page
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
    static func siteCommand(_ command: SiteCommand) -> String {
        "window.oeeeApp && window.oeeeApp.command && window.oeeeApp.command(\(literal(command.rawValue)));"
    }

    /// This device's push token, `token`, for the page to register for whoever is signed in
    /// on it (WebController). Run with `callAsyncJavaScript`.
    static let pushToken =
        "window.oeeeApp && window.oeeeApp.pushToken && window.oeeeApp.pushToken(token);"

    /// What a sign-in sheet came to, `told` (SignIn.Told), for the page to carry on with
    /// (app_sign_in.jinja). Run with `callAsyncJavaScript`.
    static let signInAnswer =
        "window.oeeeApp && window.oeeeApp.signIn && window.oeeeApp.signIn.answer(told);"

    /// What the saved-password sheet came to, `told` (SavedPassword), for the page to fill
    /// its form with (app_saved_password.jinja). Run with `callAsyncJavaScript`.
    static let passwordAnswer =
        "window.oeeeApp && window.oeeeApp.password && window.oeeeApp.password.answer(told);"

    /// The browser a sign-in was handed to has finished (BrowserSignIn): the page claims the
    /// sign-in now rather than at its next turn of asking (app_sign_in.jinja). Run with
    /// `callAsyncJavaScript`.
    static let signInResume = """
        window.oeeeApp && window.oeeeApp.signIn && window.oeeeApp.signIn.resume \
        && window.oeeeApp.signIn.resume();
        """

    /// The browser a sign-in was handed to could not be opened, or was put away without
    /// finishing (BrowserSignIn): the page stops waiting for it, so its button works again.
    /// Run with `callAsyncJavaScript`.
    static let signInUnopened = """
        window.oeeeApp && window.oeeeApp.signIn && window.oeeeApp.signIn.unopened \
        && window.oeeeApp.signIn.unopened();
        """

    /// The store's prices, `prices`, for the Supporter Pack's buttons (SupporterPack,
    /// supporter.jinja). Run with `callAsyncJavaScript`.
    static let storePrices = """
        window.oeeeApp && window.oeeeApp.store && window.oeeeApp.store.prices \
        && window.oeeeApp.store.prices(prices);
        """

    /// How a press that handed the page no proof ended, `outcome` (SupporterPack,
    /// app_store.jinja). Run with `callAsyncJavaScript`.
    static let storeEnded = """
        window.oeeeApp && window.oeeeApp.store && window.oeeeApp.store.ended \
        && window.oeeeApp.store.ended(outcome);
        """

    /// Transaction ids, `ids`, for the site to take, answered with the ids it took
    /// (SupporterPack, app_store.jinja). Run with `callAsyncJavaScript`.
    static let storePurchased = """
        return window.oeeeApp && window.oeeeApp.store && window.oeeeApp.store.purchased \
        ? await window.oeeeApp.store.purchased(ids) : [];
        """

    /// Every script above, one command standing for each kind made per command, for the
    /// contract test.
    static var all: [String] {
        [
            wouldLoseWork, leaving, preferPen, painterCommand("toggle-eraser"),
            siteCommand(.recent), pushToken, signInAnswer, signInResume, signInUnopened, passwordAnswer,
            storePrices, storeEnded, storePurchased,
        ]
    }

    /// `string` as a JavaScript string literal.
    static func literal(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

/// The site's commands the Mac's menu bar asks for (toolbar.jinja in oeee-cafe/web), by the
/// names `oeeeApp.command` takes, which the contract lists (appContract.json's `commands`).
enum SiteCommand: String, CaseIterable {
    case recent, following, communities, together, tags, search, notifications, drafts
    case profile, account, about, shortcuts, jump
    case newDrawing = "new-drawing"
    case themeLight = "theme-light"
    case themeDark = "theme-dark"
    case themeSystem = "theme-system"
}
