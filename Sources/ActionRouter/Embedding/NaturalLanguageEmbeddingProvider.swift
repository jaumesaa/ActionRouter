import Foundation
import NaturalLanguage

/// Embedding provider backed by Apple's `NLContextualEmbedding`
/// (macOS 14+ / iOS 17+): a multilingual transformer shipped with the OS,
/// so it adds nothing to the app bundle.
///
/// - Warning: Benchmarks show this provider's sentence-level similarity is
///   weakly discriminative — on the project's dev suites it *lowered*
///   ranking accuracy versus lexical-only routing and made abstention
///   unreliable (see `docs/architecture-decision.md`). It exists for
///   zero-download experimentation; for production use the Core ML
///   E5 provider from the `ActionRouterCoreML` module.
///
/// Notes:
/// - Models are per-*script* (the default `.latin` model covers English,
///   Spanish, Catalan, French, German, Portuguese, Italian, …). Vectors
///   from different script models are not comparable, so pick the script
///   your users type in.
/// - The OS may need to download model assets once. `prepare()` requests
///   them; in a sandboxed app this uses the system asset mechanism and
///   needs no special entitlement, but it does need network the first time.
///   After that, routing is fully offline.
public actor NaturalLanguageEmbeddingProvider: EmbeddingProvider {
    public nonisolated let identifier: String

    private let script: NLScript
    private var embedding: NLContextualEmbedding?

    public init(script: NLScript = .latin) {
        self.script = script
        self.identifier = "apple.nl.contextual.\(script.rawValue)"
    }

    /// Whether the OS has embedding assets for the script already installed
    /// (no download needed).
    public static func hasInstalledAssets(script: NLScript = .latin) -> Bool {
        NLContextualEmbedding(script: script)?.hasAvailableAssets ?? false
    }

    public func prepare() async throws {
        guard embedding == nil else { return }
        guard let model = NLContextualEmbedding(script: script) else {
            throw EmbeddingError.unsupported(
                "NLContextualEmbedding has no model for script \(script.rawValue)"
            )
        }
        if !model.hasAvailableAssets {
            let result = try await model.requestAssets()
            guard result == .available else {
                throw EmbeddingError.assetsUnavailable(
                    "NLContextualEmbedding assets for \(script.rawValue): \(result)"
                )
            }
        }
        try model.load()
        embedding = model
    }

    public func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        if embedding == nil {
            try await prepare()
        }
        guard let embedding else {
            throw EmbeddingError.unsupported("provider not prepared")
        }
        return try texts.map { text in
            let result = try embedding.embeddingResult(for: text, language: nil)
            var sum = [Double](repeating: 0, count: embedding.dimension)
            var tokenCount = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for (index, value) in vector.enumerated() where index < sum.count {
                    sum[index] += value
                }
                tokenCount += 1
                return true
            }
            guard tokenCount > 0 else { throw EmbeddingError.emptyResult }
            // Mean pooling over token vectors gives the sentence vector.
            return sum.map { Float($0 / Double(tokenCount)) }
        }
    }
}
