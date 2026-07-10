/// A routable capability offered by the host application.
///
/// Actions are plain data: the router never executes them, it only decides
/// which one best matches a natural-language request. Register richer
/// metadata (keywords, usage examples) to improve routing quality — every
/// field is optional except `id` and `name`.
public struct Action: Identifiable, Hashable, Sendable {
    /// Stable unique identifier, chosen by the host application.
    public let id: String

    /// Short human-readable name, e.g. "Convert audio to WAV".
    public var name: String

    /// One or two sentences describing what the action does.
    public var description: String

    /// Terms strongly associated with the action, e.g. formats or synonyms.
    public var keywords: [String]

    /// Example requests a user might type to invoke this action.
    public var examples: [String]

    /// Free-form key/value pairs. Values are indexed with low weight, so
    /// putting supported formats or domain terms here helps routing.
    public var metadata: [String: String]

    public init(
        id: String,
        name: String,
        description: String = "",
        keywords: [String] = [],
        examples: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.keywords = keywords
        self.examples = examples
        self.metadata = metadata
    }
}

extension Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, description, keywords, examples, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        self.examples = try container.decodeIfPresent([String].self, forKey: .examples) ?? []
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}
