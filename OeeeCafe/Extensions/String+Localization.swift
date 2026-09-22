import Foundation

extension String {
    /// Returns the localized version of this string
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }
}
