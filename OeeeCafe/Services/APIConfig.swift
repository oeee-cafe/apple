import Foundation

class APIConfig {
    static let shared = APIConfig()

    private init() {}

    /// The site. The native app's developer mode could point it elsewhere; nothing can set
    /// that or take it back any more, so a device left pointed at a staging server would
    /// stay there for good, and it is no longer read.
    let baseURL = "https://oeee.cafe"

    /// The site itself, which every page of it is under.
    var url: URL { URL(string: baseURL)! }
}
