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

    /// The tab whose own page this is: a tab's root, and nothing below it. A page deeper
    /// in the site is a screen pushed onto whichever tab it was opened from, and belongs
    /// to no tab of its own.
    static func owning(path: String) -> WebTab? {
        let here = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return allCases.first { $0.path == here }
    }

    /// The tab a page of the site belongs in, by where it is: notifications and
    /// communities have tabs of their own, and everything else is found from home.
    static func showing(path: String) -> WebTab {
        if path.hasPrefix(WebTab.notifications.path) {
            return .notifications
        } else if path.hasPrefix(WebTab.communities.path) {
            return .communities
        }
        return .home
    }
}
