/// Identifies one scoring signal contributing to a match.
///
/// Extensible: custom backends can define their own signals.
public struct RoutingSignal: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    // Lexical tier
    public static let exactName = RoutingSignal(rawValue: "lexical.exactName")
    public static let namePrefix = RoutingSignal(rawValue: "lexical.namePrefix")
    public static let tokenSupport = RoutingSignal(rawValue: "lexical.tokenSupport")
    public static let phraseSimilarity = RoutingSignal(rawValue: "lexical.phraseSimilarity")
    public static let bm25 = RoutingSignal(rawValue: "lexical.bm25")

    // Context
    public static let contextAffinity = RoutingSignal(rawValue: "context.affinity")

    // Semantic tier (Phase 2)
    public static let semanticSimilarity = RoutingSignal(rawValue: "semantic.similarity")
}

/// A candidate action with its confidence and per-signal score breakdown.
public struct RouteMatch: Sendable {
    /// The candidate action.
    public let action: Action

    /// Confidence in [0, 1] that this action is what the user meant.
    ///
    /// - Note: In the current pre-release this value is a documented
    ///   heuristic, not a statistically calibrated probability. Calibration
    ///   against benchmark data lands in a later phase.
    public let confidence: Double

    /// Fused relevance score in [0, 1] before confidence adjustment.
    public let fusedScore: Double

    /// Raw per-signal scores, each normalized to [0, 1]. Useful for
    /// diagnosing why an action ranked where it did.
    public let signals: [RoutingSignal: Double]
}

/// Why the router declined to pick an action.
public enum AbstentionReason: Sendable, Equatable {
    /// The query was empty or contained no usable content.
    case emptyQuery
    /// No actions are registered.
    case noActionsRegistered
    /// The best candidate's confidence fell below the configured minimum.
    case insufficientConfidence(best: Double, required: Double)
    /// Two or more candidates were too close to call and the policy
    /// requires abstaining on ambiguity.
    case ambiguous(margin: Double, required: Double)
}

/// The outcome of routing one query against the registered actions.
public struct RoutingResult: Sendable {
    public enum Decision: Sendable {
        /// The router selected an action.
        case matched(RouteMatch)
        /// The router decided no registered action is suitable enough.
        case abstained(AbstentionReason)
    }

    /// The query as received.
    public let query: String

    /// The routing decision.
    public let decision: Decision

    /// Ranked candidates (best first), capped at
    /// `RouterConfiguration.maxCandidates`. Present even when abstaining,
    /// so callers can show "closest matches" UI or diagnose the abstention.
    public let candidates: [RouteMatch]

    /// Wall-clock time spent routing.
    public let duration: Duration

    /// The selected match, if any.
    public var match: RouteMatch? {
        if case .matched(let match) = decision { return match }
        return nil
    }

    /// Ranked alternatives excluding the selected match (all candidates
    /// when the router abstained).
    public var alternatives: [RouteMatch] {
        if case .matched = decision { return Array(candidates.dropFirst()) }
        return candidates
    }
}
