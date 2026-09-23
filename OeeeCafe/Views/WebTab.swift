import Foundation

/// A tab of the native tab bar, each showing its own page of the site.
enum WebTab: String, CaseIterable {
    case home
    case communities
    case notifications
    case login
    case search

    var path: String {
        switch self {
        case .home: return "/"
        case .communities: return "/communities"
        case .notifications: return "/notifications"
        case .login: return "/login"
        case .search: return "/search"
        }
    }

    var title: String {
        switch self {
        case .home: return "tab.home".localized
        case .communities: return "tab.communities".localized
        case .notifications: return "tab.notifications".localized
        case .login: return "tab.login".localized
        case .search: return "tab.search".localized
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .communities: return "person.3.fill"
        case .notifications: return "bell"
        case .login: return "person.circle"
        case .search: return "magnifyingglass"
        }
    }

    static func visible(isAuthenticated: Bool) -> [WebTab] {
        isAuthenticated
            ? [.home, .communities, .notifications, .search]
            : [.home, .communities, .login, .search]
    }

    var rootURL: URL {
        URL(string: APIConfig.shared.baseURL + path)!
    }

    /// The tab a page of the site belongs in: the sections with a tab of their own carry
    /// everything below them, and home is the site's own front page.
    ///
    /// Nil for a page that is nobody's section -- a drawing, a profile, what somebody
    /// wrote, the pages the toolbar has and the tab bar does not. Those are read in
    /// whichever section they were opened from, and leave the bar where it is, as stepping
    /// into one used to leave the reader in the tab they stepped from.
    static func showing(path: String) -> WebTab? {
        let here = path.isEmpty ? "/" : path
        if here == home.path { return .home }
        return [.notifications, .communities, .login, .search].first { here.hasPrefix($0.path) }
    }
}
