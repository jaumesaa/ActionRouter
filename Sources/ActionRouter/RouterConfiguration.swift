/// Controls when the router abstains instead of returning a match.
public struct AbstentionPolicy: Sendable {
    /// Minimum confidence for the top candidate to be returned as a match.
    public var minimumConfidence: Double

    /// Minimum fused-score gap between the top two candidates before the
    /// result counts as ambiguous. Only enforced when
    /// `abstainOnAmbiguity` is true.
    public var minimumMargin: Double

    /// When true, the router abstains with `.ambiguous` if the top two
    /// candidates are closer than `minimumMargin`. When false (default),
    /// close calls are still returned as matches, with the runner-up
    /// visible in `alternatives`.
    public var abstainOnAmbiguity: Bool

    public init(
        minimumConfidence: Double = 0.35,
        minimumMargin: Double = 0.08,
        abstainOnAmbiguity: Bool = false
    ) {
        self.minimumConfidence = minimumConfidence
        self.minimumMargin = minimumMargin
        self.abstainOnAmbiguity = abstainOnAmbiguity
    }

    public static let `default` = AbstentionPolicy()
}

/// Tuning for the lexical scoring tier.
///
/// Defaults are sensible for action sets of a few dozen to a few hundred
/// entries; most integrations should not need to touch them.
public struct LexicalConfiguration: Sendable {
    /// Relative weight of each signal in the fused score. Weights are
    /// normalized internally, so only their ratios matter.
    public var signalWeights: [RoutingSignal: Double]

    /// Additional boost (0...1 scale) applied from context hint matches.
    public var contextWeight: Double

    /// Per-field weight multipliers used when indexing action text.
    public var nameWeight: Double
    public var keywordWeight: Double
    public var exampleWeight: Double
    public var descriptionWeight: Double
    public var metadataWeight: Double

    public init(
        signalWeights: [RoutingSignal: Double] = [
            .tokenSupport: 0.50,
            .bm25: 0.20,
            .phraseSimilarity: 0.15,
            .namePrefix: 0.15,
        ],
        contextWeight: Double = 0.10,
        nameWeight: Double = 1.0,
        keywordWeight: Double = 0.9,
        exampleWeight: Double = 0.7,
        descriptionWeight: Double = 0.5,
        metadataWeight: Double = 0.4
    ) {
        self.signalWeights = signalWeights
        self.contextWeight = contextWeight
        self.nameWeight = nameWeight
        self.keywordWeight = keywordWeight
        self.exampleWeight = exampleWeight
        self.descriptionWeight = descriptionWeight
        self.metadataWeight = metadataWeight
    }

    public static let `default` = LexicalConfiguration()
}

/// Top-level router configuration. `RouterConfiguration.default` requires
/// no machine-learning knowledge and works out of the box.
public struct RouterConfiguration: Sendable {
    /// Abstention behaviour.
    public var abstention: AbstentionPolicy

    /// Maximum number of ranked candidates returned in a `RoutingResult`.
    public var maxCandidates: Int

    /// Lexical tier tuning.
    public var lexical: LexicalConfiguration

    public init(
        abstention: AbstentionPolicy = .default,
        maxCandidates: Int = 5,
        lexical: LexicalConfiguration = .default
    ) {
        self.abstention = abstention
        self.maxCandidates = maxCandidates
        self.lexical = lexical
    }

    public static let `default` = RouterConfiguration()
}
