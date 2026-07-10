import Foundation

/// Precomputed lexical features for one registered action.
struct IndexedAction {
    let action: Action

    /// Normalized full name, e.g. "convert audio to wav".
    let normalizedName: String

    /// Trigram set of the normalized name (typo-tolerant phrase matching).
    let nameTrigrams: Set<String>

    /// Trigram sets of normalized keyword phrases.
    let keywordTrigrams: [Set<String>]

    /// Unique token → highest field weight it appears with.
    let tokenWeights: [String: Double]

    /// Weighted term frequencies for BM25F-style scoring.
    let termFrequencies: [String: Double]

    /// Weighted document length (sum of term frequencies).
    let documentLength: Double

    init(action: Action, configuration: LexicalConfiguration) {
        self.action = action
        self.normalizedName = TextNormalizer.normalize(action.name)
        self.nameTrigrams = StringMetrics.trigrams(of: normalizedName)
        self.keywordTrigrams = action.keywords.map {
            StringMetrics.trigrams(of: TextNormalizer.normalize($0))
        }

        var weights: [String: Double] = [:]
        var frequencies: [String: Double] = [:]
        var length = 0.0

        func index(_ texts: [String], weight: Double) {
            for text in texts {
                for token in TextNormalizer.tokenize(text) {
                    weights[token] = Swift.max(weights[token] ?? 0, weight)
                    frequencies[token, default: 0] += weight
                    length += weight
                }
            }
        }

        index([action.name], weight: configuration.nameWeight)
        index(action.keywords, weight: configuration.keywordWeight)
        index(action.examples, weight: configuration.exampleWeight)
        index([action.description], weight: configuration.descriptionWeight)
        index(Array(action.metadata.values), weight: configuration.metadataWeight)

        self.tokenWeights = weights
        self.termFrequencies = frequencies
        self.documentLength = length
    }
}

/// Corpus-level statistics for BM25, rebuilt when the action set changes.
/// Rebuilding is O(total tokens), which is negligible at the intended scale
/// (dozens to a few hundred actions).
struct CorpusStatistics {
    let documentCount: Int
    let averageDocumentLength: Double
    let documentFrequencies: [String: Int]

    init(indexed: [IndexedAction]) {
        self.documentCount = indexed.count
        let totalLength = indexed.reduce(0.0) { $0 + $1.documentLength }
        self.averageDocumentLength =
            indexed.isEmpty ? 0 : totalLength / Double(indexed.count)
        var frequencies: [String: Int] = [:]
        for document in indexed {
            for token in document.termFrequencies.keys {
                frequencies[token, default: 0] += 1
            }
        }
        self.documentFrequencies = frequencies
    }

    func inverseDocumentFrequency(of token: String) -> Double {
        let df = Double(documentFrequencies[token] ?? 0)
        let n = Double(documentCount)
        return Foundation.log(1.0 + (n - df + 0.5) / (df + 0.5))
    }
}
