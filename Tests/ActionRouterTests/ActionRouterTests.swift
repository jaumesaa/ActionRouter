import Foundation
import Testing

@testable import ActionRouter

private func makeFileToolRouter() async -> ActionRouter {
    let router = ActionRouter()
    await router.register([
        Action(
            id: "audio-to-wav",
            name: "Convert audio to WAV",
            description: "Converts audio files to the WAV format.",
            keywords: ["wav", "audio", "convert", "format"],
            examples: ["convert this song to wav", "make this file a wav"]
        ),
        Action(
            id: "remove-background",
            name: "Remove image background",
            description: "Removes the background from a picture.",
            keywords: ["background", "image", "transparent", "png"],
            examples: ["remove the background from this photo"]
        ),
        Action(
            id: "compress-video",
            name: "Compress video",
            description: "Reduces the file size of a video.",
            keywords: ["video", "compress", "smaller", "size"],
            examples: ["make this video smaller"]
        ),
        Action(
            id: "trim-audio",
            name: "Trim audio",
            description: "Cuts a section out of an audio file.",
            keywords: ["trim", "cut", "audio", "clip"],
            examples: ["cut the first 10 seconds of this song"]
        ),
    ])
    return router
}

// The exact example from the product brief, kept as a permanent regression test.
@Test func briefExampleRoutesToWavConversion() async throws {
    let router = ActionRouter()
    await router.register([
        Action(id: "wav", name: "Convert audio to WAV"),
        Action(id: "bg", name: "Remove image background"),
    ])
    let result = try await router.route("convertir a wav")
    #expect(result.match?.action.id == "wav")
}

@Test func exactNameMatchHasVeryHighConfidence() async throws {
    let router = await makeFileToolRouter()
    let result = try await router.route("convert audio to wav")
    let match = try #require(result.match)
    #expect(match.action.id == "audio-to-wav")
    #expect(match.confidence > 0.9)
}

@Test func toleratesTypos() async throws {
    let router = await makeFileToolRouter()
    let result = try await router.route("comprss the vidoe")
    #expect(result.match?.action.id == "compress-video")
}

@Test func toleratesDiacriticsAndCase() async throws {
    let router = await makeFileToolRouter()
    let result = try await router.route("COMPRIMIR VÍDEO")
    // "vídeo" must fold to "video"; "comprimir" shares a prefix with "compress".
    #expect(result.match?.action.id == "compress-video")
}

@Test func supportsPartialTypingPrefix() async throws {
    let router = await makeFileToolRouter()
    let result = try await router.route("trim aud")
    #expect(result.match?.action.id == "trim-audio")
}

@Test func abstainsOnUnsupportedRequest() async throws {
    let router = await makeFileToolRouter()
    let result = try await router.route("order a pizza for dinner")
    guard case .abstained(let reason) = result.decision else {
        Issue.record("Expected abstention, got \(result.decision)")
        return
    }
    guard case .insufficientConfidence = reason else {
        Issue.record("Expected insufficientConfidence, got \(reason)")
        return
    }
}

@Test func abstainsOnEmptyQuery() async throws {
    let router = await makeFileToolRouter()
    let result = try await router.route("   ")
    guard case .abstained(.emptyQuery) = result.decision else {
        Issue.record("Expected .emptyQuery abstention")
        return
    }
}

@Test func abstainsWhenNoActionsRegistered() async throws {
    let router = ActionRouter()
    let result = try await router.route("convert to wav")
    guard case .abstained(.noActionsRegistered) = result.decision else {
        Issue.record("Expected .noActionsRegistered abstention")
        return
    }
}

@Test func dynamicRegistrationAndRemoval() async throws {
    let router = await makeFileToolRouter()

    // A new action becomes routable immediately, with no retraining step.
    await router.register(Action(
        id: "pdf-merge",
        name: "Merge PDF documents",
        keywords: ["pdf", "merge", "combine", "join"]
    ))
    var result = try await router.route("merge pdfs")
    #expect(result.match?.action.id == "pdf-merge")

    // And stops being routable the moment it is removed.
    await router.remove(ids: ["pdf-merge"])
    result = try await router.route("merge pdfs")
    #expect(result.match?.action.id != "pdf-merge")

    let remaining = await router.registeredActions.map(\.id)
    #expect(!remaining.contains("pdf-merge"))
}

@Test func reRegisteringSameIDReplacesAction() async throws {
    let router = ActionRouter()
    await router.register(Action(id: "x", name: "Old name", keywords: ["oldterm"]))
    await router.register(Action(id: "x", name: "Resize image", keywords: ["resize"]))

    let actions = await router.registeredActions
    #expect(actions.count == 1)
    #expect(actions[0].name == "Resize image")

    let result = try await router.route("oldterm")
    if case .matched(let match) = result.decision {
        #expect(match.confidence < 0.5, "stale index entry should not match strongly")
    }
}

@Test func ambiguityLowersConfidence() async throws {
    // One clear action vs. two near-duplicates: the near-duplicates should
    // yield a lower-confidence top match than the singleton case.
    let single = ActionRouter()
    await single.register([
        Action(id: "a", name: "Rotate image left"),
        Action(id: "z", name: "Merge PDF documents"),
    ])
    let singleResult = try await single.route("rotate the image")

    let duplicated = ActionRouter()
    await duplicated.register([
        Action(id: "a", name: "Rotate image left"),
        Action(id: "b", name: "Rotate image right"),
        Action(id: "z", name: "Merge PDF documents"),
    ])
    let duplicatedResult = try await duplicated.route("rotate the image")

    let singleConfidence = try #require(singleResult.match?.confidence)
    let duplicatedConfidence = try #require(duplicatedResult.match?.confidence)
    #expect(duplicatedConfidence < singleConfidence)

    // Both rotate actions must appear as top candidates.
    let topIDs = duplicatedResult.candidates.prefix(2).map(\.action.id)
    #expect(Set(topIDs) == Set(["a", "b"]))
}

@Test func ambiguityAbstentionPolicy() async throws {
    var configuration = RouterConfiguration.default
    configuration.abstention.abstainOnAmbiguity = true
    configuration.abstention.minimumMargin = 0.05

    let router = ActionRouter(configuration: configuration)
    await router.register([
        Action(id: "a", name: "Rotate image left"),
        Action(id: "b", name: "Rotate image right"),
    ])
    let result = try await router.route("rotate image")
    guard case .abstained(.ambiguous) = result.decision else {
        Issue.record("Expected ambiguity abstention, got \(result.decision)")
        return
    }
    #expect(result.candidates.count == 2)
}

@Test func contextHintsBreakTies() async throws {
    let router = ActionRouter()
    await router.register([
        Action(
            id: "compress-video", name: "Compress video",
            metadata: ["formats": "mp4 mov avi"]
        ),
        Action(
            id: "compress-image", name: "Compress image",
            metadata: ["formats": "png jpg heic"]
        ),
    ])

    let videoContext = RoutingContext(hints: ["mp4"])
    let videoResult = try await router.route("compress this", context: videoContext)
    #expect(videoResult.match?.action.id == "compress-video")

    let imageContext = RoutingContext(hints: ["png"])
    let imageResult = try await router.route("compress this", context: imageContext)
    #expect(imageResult.match?.action.id == "compress-image")
}

@Test func contextAloneNeverMatches() async throws {
    let router = await makeFileToolRouter()
    let context = RoutingContext(hints: ["wav", "audio"])
    let result = try await router.route("who won the football game", context: context)
    guard case .abstained = result.decision else {
        Issue.record("Context hints alone must not produce a match")
        return
    }
}

@Test func candidatesAreRankedAndCapped() async throws {
    var configuration = RouterConfiguration.default
    configuration.maxCandidates = 2
    let router = ActionRouter(configuration: configuration)
    await router.register([
        Action(id: "a", name: "Convert audio to WAV"),
        Action(id: "b", name: "Convert audio to MP3"),
        Action(id: "c", name: "Convert audio to FLAC"),
        Action(id: "d", name: "Remove image background"),
    ])
    let result = try await router.route("convert to wav")
    #expect(result.candidates.count == 2)
    #expect(result.candidates[0].fusedScore >= result.candidates[1].fusedScore)
    #expect(result.match?.action.id == "a")
}

@Test func actionDecodesFromMinimalJSON() throws {
    let json = #"[{"id": "wav", "name": "Convert audio to WAV"}]"#
    let actions = try JSONDecoder().decode([Action].self, from: Data(json.utf8))
    #expect(actions.count == 1)
    #expect(actions[0].id == "wav")
    #expect(actions[0].keywords.isEmpty)
}

@Test func resultIncludesDiagnostics() async throws {
    let router = await makeFileToolRouter()
    let result = try await router.route("convert to wav")
    let match = try #require(result.match)
    #expect(match.signals[.tokenSupport] ?? 0 > 0)
    #expect(result.duration > .zero)
}
