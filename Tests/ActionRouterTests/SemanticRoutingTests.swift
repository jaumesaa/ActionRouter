import Foundation
import Testing

@testable import ActionRouter

/// Deterministic embedding provider for tests: a text's vector is the
/// normalized sum of basis vectors for every vocabulary key it contains.
/// Texts sharing vocabulary keys are similar; others are orthogonal.
actor MockEmbeddingProvider: EmbeddingProvider {
    nonisolated let identifier = "test.mock"

    private let vocabulary: [String: Int]
    private let dimensions: Int
    private(set) var embedCallCount = 0
    private(set) var embeddedTextCount = 0
    let failOnPrepare: Bool

    init(vocabulary: [String: Int], dimensions: Int = 16, failOnPrepare: Bool = false) {
        self.vocabulary = vocabulary
        self.dimensions = dimensions
        self.failOnPrepare = failOnPrepare
    }

    func prepare() async throws {
        if failOnPrepare {
            throw EmbeddingError.assetsUnavailable("mock provider configured to fail")
        }
    }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        if failOnPrepare {
            throw EmbeddingError.assetsUnavailable("mock provider configured to fail")
        }
        embedCallCount += 1
        embeddedTextCount += texts.count
        return texts.map { text in
            let lowered = text.lowercased()
            var vector = [Float](repeating: 0, count: dimensions)
            for (term, axis) in vocabulary where lowered.contains(term) {
                vector[axis % dimensions] += 1
            }
            if vector.allSatisfy({ $0 == 0 }) {
                // Unknown text: reserved axis, orthogonal to every
                // vocabulary axis (which must stay below dimensions - 1).
                vector[dimensions - 1] = 1
            }
            return vector
        }
    }
}

private let crossLingualVocabulary: [String: Int] = [
    // "background removal" concept, in Catalan and English
    "fons": 0, "background": 0,
    // "audio conversion" concept: "wav"/"cancion" share an axis, while
    // "audio" gets its own, so a query hitting only one axis has partial
    // (unsaturated) similarity to the audio action document.
    "wav": 1, "cancion": 1, "audio": 4,
    // "video compression" concept
    "video": 2, "compress": 2,
]

private func makeSemanticRouter(
    provider: MockEmbeddingProvider
) async -> ActionRouter {
    let router = ActionRouter(embeddingProvider: provider)
    await router.register([
        Action(
            id: "remove-background",
            name: "Remove image background",
            description: "Removes the background from a picture."
        ),
        Action(
            id: "audio-to-wav",
            name: "Convert audio to WAV",
            description: "Converts audio files to the WAV format."
        ),
        Action(
            id: "compress-video",
            name: "Compress video",
            description: "Reduces the file size of a video."
        ),
    ])
    return router
}

// A Catalan query with zero lexical overlap must route via the semantic tier.
@Test func crossLingualQueryRoutesSemantically() async throws {
    let provider = MockEmbeddingProvider(vocabulary: crossLingualVocabulary)
    let router = await makeSemanticRouter(provider: provider)

    let result = try await router.route("treu el fons de la foto")
    let match = try #require(result.match)
    #expect(match.action.id == "remove-background")
    #expect(match.signals[.semanticSimilarity] ?? 0 > 0.5)
    // No lexical support for this query.
    #expect(match.signals[.tokenSupport] ?? 0 < 0.2)

    let status = await router.semanticStatus
    #expect(status == .ready)
}

// A failing provider must degrade to lexical-only routing, not break routing.
@Test func failingProviderDegradesToLexical() async throws {
    let provider = MockEmbeddingProvider(
        vocabulary: crossLingualVocabulary, failOnPrepare: true
    )
    let router = await makeSemanticRouter(provider: provider)

    let status = await router.semanticStatus
    guard case .unavailable = status else {
        Issue.record("Expected .unavailable status, got \(status)")
        return
    }

    // Lexical routing still works.
    let result = try await router.route("convert audio to wav")
    #expect(result.match?.action.id == "audio-to-wav")
    #expect(result.match?.signals[.semanticSimilarity] == nil)
}

@Test func semanticStatusIsDisabledWithoutProvider() async throws {
    let router = ActionRouter()
    await router.register(Action(id: "a", name: "Anything"))
    let status = await router.semanticStatus
    #expect(status == .disabled)
}

// Unchanged action texts must be served from the embedding cache.
@Test func reRegisteringUnchangedActionsUsesCache() async throws {
    let provider = MockEmbeddingProvider(vocabulary: crossLingualVocabulary)
    let router = await makeSemanticRouter(provider: provider)

    let countAfterFirst = await provider.embeddedTextCount
    let actions = await router.registeredActions
    await router.register(actions)
    let countAfterSecond = await provider.embeddedTextCount
    #expect(countAfterSecond == countAfterFirst)
}

// With equal semantic evidence, added lexical agreement must increase the
// fused score. Both queries hit the audio action on the same embedding
// axis (partial cosine ≈ 0.71), but only the first also matches lexically.
@Test func agreementBoostsFusedScore() async throws {
    let provider = MockEmbeddingProvider(vocabulary: crossLingualVocabulary)
    let router = await makeSemanticRouter(provider: provider)

    // Semantic hit ("cancion" → wav axis) + lexical hit ("wav" token).
    let agreeing = try await router.route("convertir la cancion a wav")
    // Same semantic hit, zero lexical overlap.
    let semanticOnly = try await router.route("pasar la cancion al ordenador")

    let agreeingMatch = try #require(agreeing.match)
    let semanticMatch = try #require(semanticOnly.match)
    #expect(agreeingMatch.action.id == "audio-to-wav")
    #expect(semanticMatch.action.id == "audio-to-wav")

    let agreeingSemantic = try #require(agreeingMatch.signals[.semanticSimilarity])
    let onlySemantic = try #require(semanticMatch.signals[.semanticSimilarity])
    #expect(abs(agreeingSemantic - onlySemantic) < 1e-6, "semantic evidence should be equal")
    #expect(agreeingMatch.fusedScore > semanticMatch.fusedScore)
}

// Semantic similarity to an *unrelated* concept must not create a match.
@Test func unrelatedQueryStillAbstainsWithSemantics() async throws {
    let provider = MockEmbeddingProvider(vocabulary: crossLingualVocabulary)
    let router = await makeSemanticRouter(provider: provider)

    let result = try await router.route("send an email to my boss")
    guard case .abstained = result.decision else {
        Issue.record("Expected abstention, got \(result.decision)")
        return
    }
}

// MARK: - Real Apple NLContextualEmbedding integration
//
// These run only when the OS embedding assets are already installed, so CI
// machines without assets skip them instead of failing.

@Test(.enabled(if: NaturalLanguageEmbeddingProvider.hasInstalledAssets()))
func appleProviderRoutesCrossLingualQueries() async throws {
    let router = ActionRouter(
        embeddingProvider: NaturalLanguageEmbeddingProvider()
    )
    await router.register([
        Action(
            id: "remove-background",
            name: "Remove image background",
            description: "Removes the background from a picture.",
            examples: ["remove the background from this photo"]
        ),
        Action(
            id: "audio-to-wav",
            name: "Convert audio to WAV",
            description: "Converts audio files to the WAV format.",
            examples: ["convert this song to wav"]
        ),
        Action(
            id: "merge-pdf",
            name: "Merge PDF documents",
            description: "Combines several PDF files into one.",
            examples: ["combine these pdfs"]
        ),
    ])

    // Spanish, no lexical overlap with the action texts.
    let result = try await router.route("quitar el fondo de la imagen")
    let match = try #require(result.match)
    #expect(match.action.id == "remove-background")

    let status = await router.semanticStatus
    #expect(status == .ready)
}

@Test(.enabled(if: NaturalLanguageEmbeddingProvider.hasInstalledAssets()))
func appleProviderProducesStableNormalizedVectors() async throws {
    let provider = NaturalLanguageEmbeddingProvider()
    let vectors = try await provider.embed(
        ["convert audio to wav", "convert audio to wav", "remove image background"],
        purpose: .document
    )
    #expect(vectors.count == 3)
    #expect(vectors[0] == vectors[1], "same text must embed identically")

    let a = try #require(VectorMath.normalized(vectors[0]))
    let b = try #require(VectorMath.normalized(vectors[2]))
    let selfSimilarity = VectorMath.dot(a, a)
    #expect(abs(selfSimilarity - 1) < 1e-3)
    #expect(VectorMath.dot(a, b) < selfSimilarity)
}
