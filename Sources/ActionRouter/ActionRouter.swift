import Foundation
import os

/// Routes short natural-language requests to the most appropriate action
/// from a dynamic set, entirely on device.
///
/// ```swift
/// let router = ActionRouter(embeddingProvider: NaturalLanguageEmbeddingProvider())
/// await router.register([
///     Action(id: "wav", name: "Convert audio to WAV"),
///     Action(id: "bg", name: "Remove image background"),
/// ])
/// let result = try await router.route("convertir a wav")
/// if let match = result.match {
///     print(match.action.name, match.confidence)
/// }
/// ```
///
/// Actions can be registered and removed at any time; no training or
/// preparation step is required. The router abstains (see
/// ``AbstentionReason``) rather than returning a poor match.
///
/// Routing always includes the lexical tier. When an ``EmbeddingProvider``
/// is supplied, a semantic tier handles paraphrases and cross-language
/// requests; if the provider fails (e.g. missing OS assets), the router
/// degrades to lexical-only and records why in ``semanticStatus``.
public actor ActionRouter {
    private var configuration: RouterConfiguration
    private let provider: (any EmbeddingProvider)?
    private let logger = Logger(subsystem: "dev.actionrouter", category: "router")

    private var indexed: [String: IndexedAction] = [:]
    private var insertionOrder: [String] = []
    private var corpus = CorpusStatistics(indexed: [])

    private var semanticEntries: [String: SemanticEntry] = [:]
    private var embeddingCache = EmbeddingCache()
    private var status: SemanticTierStatus

    public init(
        configuration: RouterConfiguration = .default,
        embeddingProvider: (any EmbeddingProvider)? = nil
    ) {
        self.configuration = configuration
        self.provider = embeddingProvider
        self.status = embeddingProvider == nil ? .disabled : .notPrepared
    }

    // MARK: - Action management

    /// Registers actions, replacing any with the same `id`. New actions are
    /// routable immediately; when a semantic provider is configured their
    /// embeddings are computed here (cached, so unchanged texts are free).
    public func register(_ actions: [Action]) async {
        for action in actions {
            if indexed[action.id] == nil {
                insertionOrder.append(action.id)
            }
            indexed[action.id] = IndexedAction(
                action: action, configuration: configuration.lexical
            )
        }
        rebuildCorpus()
        await embedActions(actions)
    }

    /// Registers a single action, replacing any with the same `id`.
    public func register(_ action: Action) async {
        await register([action])
    }

    /// Removes the actions with the given identifiers.
    public func remove(ids: some Sequence<String>) {
        let removed = Set(ids)
        guard !removed.isEmpty else { return }
        for id in removed {
            indexed.removeValue(forKey: id)
            semanticEntries.removeValue(forKey: id)
        }
        insertionOrder.removeAll { removed.contains($0) }
        rebuildCorpus()
    }

    /// Removes all registered actions.
    public func removeAll() {
        indexed.removeAll()
        semanticEntries.removeAll()
        insertionOrder.removeAll()
        rebuildCorpus()
    }

    /// The currently registered actions, in registration order.
    public var registeredActions: [Action] {
        insertionOrder.compactMap { indexed[$0]?.action }
    }

    /// Availability of the semantic tier (see ``SemanticTierStatus``).
    public var semanticStatus: SemanticTierStatus {
        status
    }

    /// Applies a new configuration without losing registered actions.
    ///
    /// Lexical indexes are rebuilt with the new field weights and, when a
    /// semantic provider is configured, action embeddings are recomputed —
    /// the content-keyed embedding cache makes unchanged texts free, so
    /// this is cheap enough for live tuning UIs.
    public func updateConfiguration(_ newConfiguration: RouterConfiguration) async {
        configuration = newConfiguration
        let actions = registeredActions
        for action in actions {
            indexed[action.id] = IndexedAction(
                action: action, configuration: configuration.lexical
            )
        }
        rebuildCorpus()
        await embedActions(actions)
    }

    /// Retries loading a previously failed embedding provider (e.g. after
    /// network became available for the one-time OS asset download) and
    /// re-embeds registered actions on success.
    public func retrySemanticPreparation() async {
        guard provider != nil, case .unavailable = status else { return }
        status = .notPrepared
        await embedActions(registeredActions)
    }

    // MARK: - Routing

    /// Routes a query against the registered actions.
    ///
    /// - Parameters:
    ///   - query: A short natural-language request, in any language.
    ///   - context: Optional application context (see ``RoutingContext``).
    /// - Returns: A ``RoutingResult`` whose `decision` is either a match or
    ///   an explicit abstention. Ranked candidates are always included.
    /// - Throws: `CancellationError` if the surrounding task is cancelled.
    public func route(
        _ query: String,
        context: RoutingContext? = nil
    ) async throws -> RoutingResult {
        let clock = ContinuousClock()
        let start = clock.now

        func finish(_ decision: RoutingResult.Decision, candidates: [RouteMatch]) -> RoutingResult {
            RoutingResult(
                query: query,
                decision: decision,
                candidates: candidates,
                duration: clock.now - start
            )
        }

        let allowed = context?.allowedActionIDs
        let candidateIDs = allowed.map { ids in insertionOrder.filter(ids.contains) }
            ?? insertionOrder
        guard !candidateIDs.isEmpty else {
            return finish(.abstained(.noActionsRegistered), candidates: [])
        }
        let parsedQuery = LexicalScorer.Query(text: query, context: context)
        guard !parsedQuery.isEmpty else {
            return finish(.abstained(.emptyQuery), candidates: [])
        }

        let queryVector = try await embedQueryIfPossible(query)
        try Task.checkCancellation()

        var scored: [(fused: Double, signals: [RoutingSignal: Double], action: Action)] = []
        scored.reserveCapacity(candidateIDs.count)
        for id in candidateIDs {
            guard let document = indexed[id] else { continue }
            var signals = LexicalScorer.signals(
                query: parsedQuery,
                action: document,
                corpus: corpus,
                configuration: configuration.lexical
            )
            let lexical = LexicalScorer.fuse(signals, configuration: configuration.lexical)

            var semantic = 0.0
            if let queryVector, let entry = semanticEntries[id] {
                let cosine = entry.bestSimilarity(to: queryVector)
                semantic = mapSimilarity(cosine)
                signals[.semanticCosine] = cosine
                signals[.semanticSimilarity] = semantic
            }

            let fused = combine(lexical: lexical, semantic: semantic)
            scored.append((fused, signals, document.action))
        }
        scored.sort { $0.fused > $1.fused }

        let margin: Double
        if scored.count >= 2 {
            margin = scored[0].fused - scored[1].fused
        } else {
            margin = scored[0].fused
        }

        let candidates = scored.prefix(Swift.max(1, configuration.maxCandidates)).map {
            RouteMatch(
                action: $0.action,
                confidence: Confidence.estimate(
                    fusedScore: $0.fused,
                    margin: $0.action.id == scored[0].action.id ? margin : 0,
                    semanticTierActive: queryVector != nil
                ),
                fusedScore: $0.fused,
                signals: $0.signals
            )
        }

        let policy = configuration.abstention
        let best = candidates[0]
        if best.confidence < policy.minimumConfidence {
            return finish(
                .abstained(.insufficientConfidence(
                    best: best.confidence, required: policy.minimumConfidence
                )),
                candidates: candidates
            )
        }
        if policy.abstainOnAmbiguity, scored.count >= 2, margin < policy.minimumMargin {
            return finish(
                .abstained(.ambiguous(margin: margin, required: policy.minimumMargin)),
                candidates: candidates
            )
        }
        return finish(.matched(best), candidates: candidates)
    }

    // MARK: - Semantic tier

    /// Combines lexical and semantic evidence. Either signal alone can
    /// carry a match (cross-language queries have no lexical overlap;
    /// format abbreviations may have no semantic weight), and agreement
    /// between the two earns a bounded bonus.
    private func combine(lexical: Double, semantic: Double) -> Double {
        let stronger = Swift.max(lexical, semantic)
        let weaker = Swift.min(lexical, semantic)
        let bonus = configuration.semantic.agreementBonus * weaker * (1 - stronger)
        return Swift.min(1, stronger + bonus)
    }

    /// Affine remap of raw cosine similarity into [0, 1] (see
    /// ``SemanticConfiguration/similarityFloor``).
    private func mapSimilarity(_ cosine: Double) -> Double {
        let floor = configuration.semantic.similarityFloor
        let ceiling = configuration.semantic.similarityCeiling
        guard ceiling > floor else { return 0 }
        return Swift.min(1, Swift.max(0, (cosine - floor) / (ceiling - floor)))
    }

    private func embedQueryIfPossible(_ query: String) async throws -> [Float]? {
        guard let provider else { return nil }
        if case .unavailable = status { return nil }
        do {
            let raw = try await provider.embed([query], purpose: .query)
            guard let vector = raw.first.flatMap(VectorMath.normalized) else {
                throw EmbeddingError.emptyResult
            }
            status = .ready
            return vector
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            markSemanticUnavailable(error)
            return nil
        }
    }

    private func embedActions(_ actions: [Action]) async {
        guard let provider else { return }
        if case .unavailable = status { return }
        do {
            try await provider.prepare()
            for action in actions {
                let texts = SemanticText.documentTexts(
                    for: action, configuration: configuration.semantic
                )
                var vectors: [[Float]] = []
                vectors.reserveCapacity(texts.count)
                var pending: [String] = []
                for text in texts {
                    if let cached = embeddingCache.vector(
                        provider: provider.identifier, purpose: .document, text: text
                    ) {
                        vectors.append(cached)
                    } else {
                        pending.append(text)
                    }
                }
                if !pending.isEmpty {
                    let embedded = try await provider.embed(pending, purpose: .document)
                    for (text, raw) in zip(pending, embedded) {
                        guard let vector = VectorMath.normalized(raw) else { continue }
                        embeddingCache.store(
                            vector, provider: provider.identifier,
                            purpose: .document, text: text
                        )
                        vectors.append(vector)
                    }
                }
                semanticEntries[action.id] = SemanticEntry(vectors: vectors)
            }
            status = .ready
        } catch {
            markSemanticUnavailable(error)
        }
    }

    private func markSemanticUnavailable(_ error: Error) {
        let reason = String(describing: error)
        status = .unavailable(reason)
        logger.warning(
            "Semantic tier unavailable, degrading to lexical routing: \(reason, privacy: .public)"
        )
    }

    // MARK: - Private

    private func rebuildCorpus() {
        corpus = CorpusStatistics(indexed: Array(indexed.values))
    }
}

/// Maps fused score and top-2 margin to a calibrated probability that the
/// top candidate is the action the user meant.
///
/// Logistic regression fitted on the DEV benchmark suites (1,450 episodes
/// each; CLINC-150/Banking77/MASSIVE, including out-of-scope and
/// gold-absent episodes as negatives) by `tools/dataprep/fit_calibration.py`
/// — see `docs/benchmarks.md`. Separate coefficients for lexical-only and
/// semantic-active routing because their fused-score distributions differ.
/// Regenerate with the script; never hand-tune.
enum Confidence {
    struct Coefficients: Sendable {
        let fused: Double
        let margin: Double
        let intercept: Double
    }

    /// Fitted on dev with the lexical tier only (ECE 0.025, Brier 0.166).
    static let lexicalOnly = Coefficients(fused: 5.5581, margin: 9.0162, intercept: -2.7450)

    /// Fitted on dev with the e5 semantic tier active (ECE 0.033, Brier 0.188).
    static let semanticActive = Coefficients(fused: 2.4226, margin: 8.9502, intercept: -2.4809)

    static func estimate(
        fusedScore: Double, margin: Double, semanticTierActive: Bool
    ) -> Double {
        let c = semanticTierActive ? semanticActive : lexicalOnly
        let z = c.fused * fusedScore + c.margin * Swift.max(0, margin) + c.intercept
        return 1 / (1 + Foundation.exp(-Swift.min(30, Swift.max(-30, z))))
    }
}
