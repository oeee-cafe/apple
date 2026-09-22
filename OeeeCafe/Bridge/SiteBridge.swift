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
            case v, type, count, name, drawing, state
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
            default:
                message = nil
            }
        }
    }
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
