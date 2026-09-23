import Foundation

/// The site, which every page the app shows is under.
enum SiteURL {
    static let root = URL(string: "https://oeee.cafe")!

    /// The site's front page, where the app opens.
    static let home = URL(string: "/", relativeTo: root)!.absoluteURL

    /// A page of the site by its path, with any query: `/@artist/9c881320?x=1`.
    static func page(_ path: String) -> URL? {
        URL(string: root.absoluteString + path)
    }

    /// Whether `url` is one of the site's own pages.
    static func contains(_ url: URL) -> Bool {
        url.host == root.host
    }
}
