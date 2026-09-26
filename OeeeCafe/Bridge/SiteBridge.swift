import Foundation
import WebKit

/// What the site tells the app about itself, on the one channel it says it on.
///
/// Each page registers nothing and reads nothing of the app's: the site calls
/// `webkit.messageHandlers.oeeeBridge.postMessage(json)` with a JSON string of
/// `{v: 1, type, ...}` (templates/app_bridge.jinja in oeee-cafe/web, which is the contract).
/// Before it, the app learned these things by reading the page -- a CSS class on the
/// unread badge, the presence meta, which images were drawings -- and each broke without
/// a word the day the site changed. Types and fields this build does not know are
/// ignored, so the site can add either without a release of the app.
enum SiteMessage: Equatable {
    case page(Page)
    case unread(count: Int)
    case theme(Theme)
    case haptic(name: String)
    case pressed(Drawing?)
    case painterReady
    /// What the App Store products on /supporter cost, and one to sell, as the store names
    /// it. The page only asks this build about its own store's (`data-store="apple"`), so
    /// neither says which store; and the site says which product is this year's pack, so
    /// this build sells whatever it is sent rather than knowing the year itself.
    case prices(products: [String])
    case purchase(product: String)
    case restore
    /// A sign-in the page is carrying (app_sign_in.jinja in oeee-cafe/web). The page decides
    /// which providers come to the app, and asks for Apple with a nonce.
    case signIn(provider: String, nonce: String?)
    /// A page of the site to open in a browser of the system's (BrowserSignIn): a sign-in
    /// the page has handed off, which is Google's. The URL is as the page sent it; the app
    /// checks it is the site's before opening it.
    case browse(url: String)
    /// The reader went to a field of a form that takes a saved password: offer them one
    /// (SavedPassword), and answer with the id the page asked with. Only the Mac's pages ask.
    case password(id: String)
    /// The Mac app's toolbar, which is its title bar: drag or zoom the window.
    case window(action: String)
    case words(Words)

    /// The version of the contract this build speaks. A message of another is a change
    /// this build does not understand, so it is left unheard rather than half-read.
    static let version = 1

    /// The page on screen: said on every page, and again when any of it changes.
    struct Page: Decodable, Equatable {
        let path: String
        /// Whether someone is signed in, or nil on a page without the toolbar, which
        /// cannot tell.
        let signedIn: Bool?
        /// Whether leaving the page would lose a drawing in progress.
        let painting: Bool
        /// Whether pulling down may reload the page: neither a painter nor a replay may be.
        let refreshable: Bool
    }

    struct Theme: Decodable, Equatable {
        /// "light", "dark" or "system".
        let choice: String
        /// The design system's ground (`--ds-ground`, ds.css in oeee-cafe/web), as a CSS
        /// colour; nil on a page without the design system's stylesheet. The page also says
        /// its grid, which this app has no use for.
        let ground: String?
    }

    /// What the app says in dialogs and menus of its own over the page, in the page's
    /// language (`words`, locales/*.ftl in oeee-cafe/web). Only what this app says is read;
    /// a word the site does not send keeps its English default, which is also what is said
    /// before any page has spoken.
    struct Words: Decodable, Equatable {
        var leaveTitle = "Leave this page?"
        var leaveBody = "Anything you have not saved will be lost."
        var leave = "Leave"
        var stay = "Stay"
        var saveImage = "Save to Photos"
        var copyImage = "Copy"
        var share = "Share…"
        var copyLink = "Copy Link"

        init() {}

        private enum Key: String, CodingKey {
            case leaveTitle, leaveBody, leave, stay, saveImage, copyImage, share, copyLink
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            func word(_ key: Key, _ fallback: String) -> String {
                guard let value = try? container.decodeIfPresent(String.self, forKey: key),
                      !value.isEmpty else { return fallback }
                return value
            }
            leaveTitle = word(.leaveTitle, leaveTitle)
            leaveBody = word(.leaveBody, leaveBody)
            leave = word(.leave, leave)
            stay = word(.stay, stay)
            saveImage = word(.saveImage, saveImage)
            copyImage = word(.copyImage, copyImage)
            share = word(.share, share)
            copyLink = word(.copyLink, copyLink)
        }
    }

    /// A drawing a finger landed on (`data-oeee-drawing`, never a sensitive one).
    struct Drawing: Decodable, Equatable {
        let src: String
        /// The post's page, or "" on the post page itself.
        let link: String
        let width: Double
        let height: Double
    }

    /// The message in `body`, or nil for one this build does not know or cannot read.
    init?(body: Any) {
        guard let text = body as? String, let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(Envelope.self, from: data).message
        else { return nil }
        self = message
    }

    /// `{v, type}` and the fields of that type, which sit beside them.
    private struct Envelope: Decodable {
        let message: SiteMessage?

        private enum Key: String, CodingKey {
            case v, type, count, name, drawing, state, product, products, provider, nonce, url, action, id
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard try container.decode(Int.self, forKey: .v) == SiteMessage.version else {
                message = nil
                return
            }
            switch try container.decode(String.self, forKey: .type) {
            case "page":
                message = .page(try Page(from: decoder))
            case "unread":
                message = .unread(count: try container.decode(Int.self, forKey: .count))
            case "theme":
                message = .theme(try Theme(from: decoder))
            case "haptic":
                message = .haptic(name: try container.decode(String.self, forKey: .name))
            case "pressed":
                message = .pressed(try container.decodeIfPresent(Drawing.self, forKey: .drawing))
            case "painter":
                message = try container.decodeIfPresent(String.self, forKey: .state) == "ready" ? .painterReady : nil
            case "prices":
                message = .prices(products: try container.decode([String].self, forKey: .products))
            case "purchase":
                message = .purchase(product: try container.decode(String.self, forKey: .product))
            case "restore":
                message = .restore
            case "signIn":
                message = .signIn(
                    provider: try container.decode(String.self, forKey: .provider),
                    nonce: try container.decodeIfPresent(String.self, forKey: .nonce)
                )
            case "browse":
                message = .browse(url: try container.decode(String.self, forKey: .url))
            case "password":
                message = .password(id: try container.decode(String.self, forKey: .id))
            case "words":
                message = .words(try Words(from: decoder))
            case "window":
                message = .window(action: try container.decode(String.self, forKey: .action))
            default:
                message = nil
            }
        }
    }
}

/// The words the page on screen last sent (`words`), for the app's own dialogs and menus
/// over it (LeaveDialog, DrawingMenu): English until a page has spoken.
enum SiteWords {
    static var current = SiteMessage.Words()
}

/// Hears `oeeeBridge` for one web view and hands what it reads to `onMessage`.
///
/// The user content controller keeps its handlers for as long as the web view lives, and
/// the web view's owner owns the web view; holding the owner only weakly, through the
/// closure, is what lets the two go.
final class SiteBridge: NSObject, WKScriptMessageHandler {
    static let name = "oeeeBridge"

    private let onMessage: (SiteMessage) -> Void

    private init(onMessage: @escaping (SiteMessage) -> Void) {
        self.onMessage = onMessage
    }

    /// Listens on `content` in the page's own world, where the site's scripts run.
    static func install(in content: WKUserContentController, onMessage: @escaping (SiteMessage) -> Void) {
        content.add(SiteBridge(onMessage: onMessage), contentWorld: .page, name: name)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the site's own pages speak for it; an embed in a frame does not.
        guard message.frameInfo.isMainFrame, let parsed = SiteMessage(body: message.body) else { return }
        onMessage(parsed)
    }
}
