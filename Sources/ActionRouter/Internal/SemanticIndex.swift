/// Builds the texts that represent an action in embedding space and holds
/// the resulting vectors.
enum SemanticText {
    /// One primary text (name + description + keywords) plus, optionally,
    /// each usage example on its own. Similarity against an action is the
    /// max over its vectors, so examples act as paraphrase anchors.
    static func documentTexts(
        for action: Action,
        configuration: SemanticConfiguration
    ) -> [String] {
        var primary = action.name
        if !action.description.isEmpty {
            primary += ". \(action.description)"
        }
        if !action.keywords.isEmpty {
            primary += " \(action.keywords.joined(separator: ", "))"
        }
        var texts = [primary]
        if configuration.embedExamples {
            texts.append(
                contentsOf: action.examples.prefix(configuration.maxExampleEmbeddings)
            )
        }
        return texts
    }
}

/// Unit-normalized embeddings for one action's document texts.
struct SemanticEntry {
    let vectors: [[Float]]

    /// Best cosine similarity between the (normalized) query vector and any
    /// of this action's vectors.
    func bestSimilarity(to queryVector: [Float]) -> Double {
        var best: Float = -1
        for vector in vectors {
            best = Swift.max(best, VectorMath.dot(vector, queryVector))
        }
        return Double(best)
    }
}

/// Session-scoped embedding cache so re-registering unchanged actions does
/// not re-embed them. Keyed by provider, purpose and exact text.
struct EmbeddingCache {
    private var storage: [String: [Float]] = [:]

    mutating func vector(
        provider: String, purpose: EmbeddingPurpose, text: String
    ) -> [Float]? {
        storage["\(provider)|\(purpose.rawValue)|\(text)"]
    }

    mutating func store(
        _ vector: [Float], provider: String, purpose: EmbeddingPurpose, text: String
    ) {
        storage["\(provider)|\(purpose.rawValue)|\(text)"] = vector
    }
}
