import Foundation

// MARK: - Helpers

// Internal (not private) so unit tests can exercise this pure string logic via @testable import.
extension String {
    /// Percent-encodes a string for use in an application/x-www-form-urlencoded body.
    /// Uses only unreserved characters (A-Z a-z 0-9 - _ . ~) as allowed, which correctly
    /// encodes +, =, &, #, @ and other characters that would corrupt a form body.
    var urlFormEncoded: String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    var htmlEscaped: String {
        var value = self
        value = value.replacingOccurrences(of: "&", with: "&amp;")
        value = value.replacingOccurrences(of: "<", with: "&lt;")
        value = value.replacingOccurrences(of: ">", with: "&gt;")
        value = value.replacingOccurrences(of: "\"", with: "&quot;")
        value = value.replacingOccurrences(of: "'", with: "&#39;")
        return value
    }
}

