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

    /// When set, routing considers only the registered actions with these
    /// identifiers. Useful when availability varies per invocation (e.g.
    /// actions applicable to the currently selected file type) without
    /// re-registering — precomputed indexes and embeddings are reused.
    ///
    /// Unknown identifiers are ignored; an empty intersection abstains with
    /// ``AbstentionReason/noActionsRegistered``.
    public var allowedActionIDs: Set<String>?

    public init(
        hints: [String] = [],
        locale: Locale? = nil,
        attributes: [String: String] = [:],
        allowedActionIDs: Set<String>? = nil
    ) {
        self.hints = hints
        self.locale = locale
        self.attributes = attributes
        self.allowedActionIDs = allowedActionIDs
    }
}
