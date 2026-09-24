import Foundation
import os

/// The app's logs, one category each, called as os.Logger is. A value interpolated into a
/// message is `<private>` outside a debugger unless it says `privacy: .public`, so what is
/// worth reading from a device -- an error's description, a page of the site -- says so,
/// and a token never does.
extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.oeee.cafe"

    /// Loading pages and files.
    static let network = Logger(subsystem: subsystem, category: "network")

    /// Signing in.
    static let auth = Logger(subsystem: subsystem, category: "auth")

    /// Everything else.
    static let app = Logger(subsystem: subsystem, category: "app")
}
