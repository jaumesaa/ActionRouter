import Foundation

/// Optional application context supplied alongside a query.
///
/// Context never selects an action on its own; it nudges scoring toward
/// actions whose indexed terms match the hints.
public struct RoutingContext: Hashable, Sendable, Codable {
    /// Free-form context strings, e.g. selected file extensions ("mp3"),
    /// the current document type, or the active app area.
    public var hints: [String]

    /// The user's locale, when known. Reserved for backends that can use it
    /// (the lexical tier is language-agnostic after Unicode folding).
    public var locale: Locale?

    /// Additional key/value context for custom backends.
    public var attributes: [String: String]

    public init(
        hints: [String] = [],
        locale: Locale? = nil,
        attributes: [String: String] = [:]
    ) {
        self.hints = hints
        self.locale = locale
        self.attributes = attributes
    }
}
