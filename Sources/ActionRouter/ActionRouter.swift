import Foundation

/// Routes short natural-language requests to the most appropriate action
/// from a dynamic set, entirely on device.
///
/// ```swift
/// let router = ActionRouter()
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
public actor ActionRouter {
    private let configuration: RouterConfiguration
    private var indexed: [String: IndexedAction] = [:]
    private var insertionOrder: [String] = []
    private var corpus = CorpusStatistics(indexed: [])

    public init(configuration: RouterConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Action management

    /// Registers actions, replacing any with the same `id`.
    public func register(_ actions: [Action]) {
        for action in actions {
            if indexed[action.id] == nil {
                insertionOrder.append(action.id)
            }
            indexed[action.id] = IndexedAction(
                action: action, configuration: configuration.lexical
            )
        }
        rebuildCorpus()
    }

    /// Registers a single action, replacing any with the same `id`.
    public func register(_ action: Action) {
        register([action])
    }

    /// Removes the actions with the given identifiers.
    public func remove(ids: some Sequence<String>) {
        let removed = Set(ids)
        guard !removed.isEmpty else { return }
        for id in removed {
            indexed.removeValue(forKey: id)
        }
        insertionOrder.removeAll { removed.contains($0) }
        rebuildCorpus()
    }

    /// Removes all registered actions.
    public func removeAll() {
        indexed.removeAll()
        insertionOrder.removeAll()
        rebuildCorpus()
    }

    /// The currently registered actions, in registration order.
    public var registeredActions: [Action] {
        insertionOrder.compactMap { indexed[$0]?.action }
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
    ) throws -> RoutingResult {
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

        guard !indexed.isEmpty else {
            return finish(.abstained(.noActionsRegistered), candidates: [])
        }
        let parsedQuery = LexicalScorer.Query(text: query, context: context)
        guard !parsedQuery.isEmpty else {
            return finish(.abstained(.emptyQuery), candidates: [])
        }

        var scored: [(fused: Double, signals: [RoutingSignal: Double], action: Action)] = []
        scored.reserveCapacity(indexed.count)
        for id in insertionOrder {
            guard let document = indexed[id] else { continue }
            try Task.checkCancellation()
            let signals = LexicalScorer.signals(
                query: parsedQuery,
                action: document,
                corpus: corpus,
                configuration: configuration.lexical
            )
            let fused = LexicalScorer.fuse(signals, configuration: configuration.lexical)
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
                    margin: $0.action.id == scored[0].action.id
                        ? margin
                        : Swift.max(0, $0.fused - scored[0].fused)
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

    // MARK: - Private

    private func rebuildCorpus() {
        corpus = CorpusStatistics(indexed: Array(indexed.values))
    }
}

/// Maps fused score and top-2 margin to a confidence value.
///
/// This is an explicit, documented heuristic for the pre-release lexical
/// tier: monotone in the fused score, discounted when the runner-up is
/// close. It is replaced by benchmark-fitted calibration in a later phase.
enum Confidence {
    static func estimate(fusedScore: Double, margin: Double) -> Double {
        let marginFactor = 0.75 + 0.25 * Swift.min(1, Swift.max(0, margin) / 0.2)
        return Swift.min(1, Swift.max(0, fusedScore * marginFactor))
    }
}
