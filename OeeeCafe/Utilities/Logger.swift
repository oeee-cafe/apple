import Foundation
import os.log

/// Centralized logging utility for the app
/// Uses OSLog for production-ready logging with proper log levels
enum Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.oeee.cafe"

    /// Logger for network-related operations
    static let network = os.Logger(subsystem: subsystem, category: "network")

    /// Logger for authentication operations
    static let auth = os.Logger(subsystem: subsystem, category: "auth")

    /// Logger for general app operations
    static let app = os.Logger(subsystem: subsystem, category: "app")

    /// Convenience methods for debug logging (only in DEBUG builds)
    static func debug(_ message: String, category: os.Logger = Logger.app) {
        #if DEBUG
        category.debug("\(message)")
        #endif
    }

    /// Log informational messages
    static func info(_ message: String, category: os.Logger = Logger.app) {
        category.info("\(message)")
    }

    /// Log warnings
    static func warning(_ message: String, category: os.Logger = Logger.app) {
        category.warning("\(message)")
    }

    /// Log errors
    static func error(_ message: String, error: Error? = nil, category: os.Logger = Logger.app) {
        if let error = error {
            category.error("\(message): \(error.localizedDescription)")
        } else {
            category.error("\(message)")
        }
    }
}
