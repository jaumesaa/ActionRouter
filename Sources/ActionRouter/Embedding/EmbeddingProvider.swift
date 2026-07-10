/// What a text is being embedded for. Asymmetric models (e.g. E5) prepend
/// different prefixes for queries and documents; symmetric providers can
/// ignore this.
public enum EmbeddingPurpose: String, Sendable {
    /// A user request being routed.
    case query
    /// Action metadata being indexed.
    case document
}

/// Produces dense vector representations of short texts, entirely on device.
///
/// Conformers must be safe to call from concurrent contexts (actors are the
/// natural fit). Returned vectors need not be normalized; the router
/// normalizes before comparing.
public protocol EmbeddingProvider: Sendable {
    /// Stable identifier used for cache keying and diagnostics,
    /// e.g. `"apple.nl.contextual.latin"`.
    var identifier: String { get }

    /// Loads model assets. Called once before the first `embed`. Throwing
    /// here marks the semantic tier unavailable (the router degrades to
    /// lexical routing and records the reason).
    func prepare() async throws

    /// Embeds a batch of texts. Must return one vector per input, all with
    /// the same dimensionality.
    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]]
}

/// Errors thrown by the built-in embedding providers.
public enum EmbeddingError: Error, Sendable, Equatable {
    /// The OS model assets are not installed and could not be fetched.
    case assetsUnavailable(String)
    /// The provider produced no vector for an input.
    case emptyResult
    /// The provider is not supported on this OS version or configuration.
    case unsupported(String)
}

/// Availability of the semantic tier on a router instance.
public enum SemanticTierStatus: Sendable, Equatable {
    /// No embedding provider was configured; routing is lexical-only.
    case disabled
    /// A provider is configured but has not been exercised yet.
    case notPrepared
    /// The provider is loaded and contributing to routing.
    case ready
    /// The provider failed; routing degraded to lexical-only.
    /// The associated value describes why.
    case unavailable(String)
}

/// Tuning for the semantic tier.
public struct SemanticConfiguration: Sendable {
    /// Cosine similarity at or below this maps to a semantic score of 0.
    /// Raw cosines from sentence embeddings occupy a narrow band, so an
    /// affine remap is needed before fusing with lexical scores.
    ///
    /// - Note: The defaults are provisional heuristics measured on the
    ///   Apple NLContextualEmbedding provider; benchmark-fitted calibration
    ///   replaces them in a later phase.
    public var similarityFloor: Double

    /// Cosine similarity at or above this maps to a semantic score of 1.
    public var similarityCeiling: Double

    /// Bonus applied when lexical and semantic evidence agree:
    /// `fused = max(lex, sem) + bonus * min(lex, sem) * (1 - max(lex, sem))`.
    public var agreementBonus: Double

    /// Embed each usage example separately (better paraphrase matching, at
    /// the cost of more embeddings per action).
    public var embedExamples: Bool

    /// Cap on per-action example embeddings.
    public var maxExampleEmbeddings: Int

    public init(
        similarityFloor: Double = 0.55,
        similarityCeiling: Double = 0.95,
        agreementBonus: Double = 0.15,
        embedExamples: Bool = true,
        maxExampleEmbeddings: Int = 8
    ) {
        self.similarityFloor = similarityFloor
        self.similarityCeiling = similarityCeiling
        self.agreementBonus = agreementBonus
        self.embedExamples = embedExamples
        self.maxExampleEmbeddings = maxExampleEmbeddings
    }

    public static let `default` = SemanticConfiguration()

    /// Provisional mapping measured for ``NaturalLanguageEmbeddingProvider``
    /// (mean-pooled NLContextualEmbedding cosines cluster high and narrow).
    public static let appleNaturalLanguage = SemanticConfiguration(
        similarityFloor: 0.55, similarityCeiling: 0.95
    )

    /// Provisional mapping measured for E5-family Core ML models
    /// (in-scope cosines ≈ 0.80–0.90, out-of-scope ≈ ≤ 0.77).
    public static let e5 = SemanticConfiguration(
        similarityFloor: 0.75, similarityCeiling: 0.90
    )
}

extension RoutingSignal {
    /// Raw (unmapped) best cosine similarity, for diagnostics/calibration.
    public static let semanticCosine = RoutingSignal(rawValue: "semantic.cosine")
}
