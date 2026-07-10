import Foundation

/// The lexical (tier 0) scorer: exact, prefix, fuzzy-token, phrase-trigram
/// and BM25 signals over precomputed action features. Pure functions; all
/// state lives in the arguments.
enum LexicalScorer {
    struct Query {
        let normalized: String
        let contentTokens: [String]
        let trigrams: Set<String>
        let contextTokens: [String]

        init(text: String, context: RoutingContext?) {
            self.normalized = TextNormalizer.normalize(
                text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let tokens = TextNormalizer.tokenize(text)
            self.contentTokens = TextNormalizer.contentTokens(tokens)
            self.trigrams = StringMetrics.trigrams(of: normalized)
            self.contextTokens = (context?.hints ?? []).flatMap(TextNormalizer.tokenize)
        }

        var isEmpty: Bool { contentTokens.isEmpty }
    }

    /// BM25 parameters (standard defaults) and the squashing constant that
    /// maps unbounded BM25 scores into [0, 1).
    private static let k1 = 1.2
    private static let b = 0.75
    private static let bm25Squash = 3.0

    static func signals(
        query: Query,
        action: IndexedAction,
        corpus: CorpusStatistics,
        configuration: LexicalConfiguration
    ) -> [RoutingSignal: Double] {
        var signals: [RoutingSignal: Double] = [:]
        signals[.exactName] = query.normalized == action.normalizedName ? 1 : 0
        signals[.namePrefix] = namePrefixScore(query: query, action: action)
        signals[.tokenSupport] = tokenSupport(
            tokens: query.contentTokens, action: action
        )
        signals[.phraseSimilarity] = phraseSimilarity(query: query, action: action)
        signals[.bm25] = bm25Score(query: query, action: action, corpus: corpus)
        if !query.contextTokens.isEmpty {
            signals[.contextAffinity] = tokenSupport(
                tokens: query.contextTokens, action: action
            )
        }
        return signals
    }

    /// Combines signals into a fused relevance score in [0, 1].
    static func fuse(
        _ signals: [RoutingSignal: Double],
        configuration: LexicalConfiguration
    ) -> Double {
        let weights = configuration.signalWeights
        let totalWeight = weights.values.reduce(0, +)
        guard totalWeight > 0 else { return 0 }

        var fused = 0.0
        for (signal, weight) in weights {
            fused += (signals[signal] ?? 0) * weight
        }
        fused /= totalWeight

        // Context is an additive nudge on top of content relevance, scaled
        // by the remaining headroom so it can break ties but never carry a
        // contentless match on its own.
        if let affinity = signals[.contextAffinity], fused > 0.05 {
            fused += configuration.contextWeight * affinity * (1 - fused)
        }

        // An exact name match is as unambiguous as lexical evidence gets.
        if signals[.exactName] == 1 {
            fused = Swift.max(fused, 0.97)
        }
        return Swift.min(1, fused)
    }

    // MARK: - Individual signals

    private static func namePrefixScore(query: Query, action: IndexedAction) -> Double {
        let name = action.normalizedName
        let queryText = query.normalized
        guard !queryText.isEmpty, !name.isEmpty else { return 0 }
        guard queryText.count >= 2, name.hasPrefix(queryText) else { return 0 }
        let coverage = Double(queryText.count) / Double(name.count)
        return 0.5 + 0.5 * coverage
    }

    /// Fraction of query tokens that find support in the action's indexed
    /// tokens, weighted by match quality and field weight. This is the
    /// backbone signal: it is absolute (does not depend on other actions),
    /// which makes it usable for abstention.
    private static func tokenSupport(tokens: [String], action: IndexedAction) -> Double {
        guard !tokens.isEmpty else { return 0 }
        var total = 0.0
        for token in tokens {
            total += bestTokenMatch(token, in: action)
        }
        return total / Double(tokens.count)
    }

    private static func bestTokenMatch(_ token: String, in action: IndexedAction) -> Double {
        // Exact token hit (cheap dictionary lookup).
        if let weight = action.tokenWeights[token] {
            return weight
        }
        var best = 0.0
        let queryCharacters = Array(token)
        for (candidate, weight) in action.tokenWeights {
            // Prefix in either direction covers live typing ("conv" →
            // "convert") and cross-language stems ("convertir" → "convert").
            if token.count >= 3, candidate.count > token.count,
               candidate.hasPrefix(token) {
                let coverage = Double(token.count) / Double(candidate.count)
                best = Swift.max(best, weight * (0.6 + 0.4 * coverage))
                continue
            }
            if candidate.count >= 4, token.count > candidate.count,
               token.hasPrefix(candidate) {
                let coverage = Double(candidate.count) / Double(token.count)
                best = Swift.max(best, weight * (0.6 + 0.4 * coverage))
                continue
            }
            // Typo tolerance: bounded edit distance on tokens of 4+ chars.
            guard token.count >= 4, candidate.count >= 4 else { continue }
            let limit = editDistanceLimit(for: Swift.max(token.count, candidate.count))
            guard limit > 0 else { continue }
            if let distance = StringMetrics.editDistance(
                queryCharacters, Array(candidate), limit: limit
            ) {
                let longest = Double(Swift.max(token.count, candidate.count))
                let similarity = 1.0 - Double(distance) / longest
                best = Swift.max(best, weight * similarity * 0.85)
            }
        }
        return best
    }

    private static func editDistanceLimit(for length: Int) -> Int {
        switch length {
        case ..<4: return 0
        case 4...5: return 1
        case 6...8: return 2
        default: return 3
        }
    }

    private static func phraseSimilarity(query: Query, action: IndexedAction) -> Double {
        var best = StringMetrics.diceSimilarity(query.trigrams, action.nameTrigrams)
        for keywordTrigrams in action.keywordTrigrams {
            best = Swift.max(
                best, StringMetrics.diceSimilarity(query.trigrams, keywordTrigrams)
            )
        }
        return best
    }

    private static func bm25Score(
        query: Query, action: IndexedAction, corpus: CorpusStatistics
    ) -> Double {
        guard corpus.documentCount > 0, corpus.averageDocumentLength > 0 else { return 0 }
        var score = 0.0
        for token in query.contentTokens {
            guard let tf = action.termFrequencies[token] else { continue }
            let idf = corpus.inverseDocumentFrequency(of: token)
            let lengthNormalization =
                1 - b + b * action.documentLength / corpus.averageDocumentLength
            score += idf * (tf * (k1 + 1)) / (tf + k1 * lengthNormalization)
        }
        // Squash the unbounded BM25 score into [0, 1).
        return score / (score + bm25Squash)
    }
}
