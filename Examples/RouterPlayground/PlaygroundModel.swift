import ActionRouter
import ActionRouterCoreML
import Foundation
import SwiftUI

/// Observable state for the playground: owns the router, re-routes on every
/// keystroke (debounced), and applies parameter changes live.
@MainActor
final class PlaygroundModel: ObservableObject {
    enum ProviderChoice: String, CaseIterable, Identifiable {
        case lexical = "Lexical only"
        case e5 = "Core ML e5 (recommended)"
        case apple = "Apple NL (weak)"
        var id: String { rawValue }
    }

    // MARK: Inputs
    @Published var query = "" { didSet { scheduleRoute() } }
    @Published var contextHints = "" { didSet { scheduleRoute() } }
    @Published var providerChoice: ProviderChoice = .lexical {
        didSet { rebuildRouter() }
    }

    // MARK: Action set
    @Published private(set) var actions: [Action] = []
    @Published var enabledIDs: Set<String> = [] { didSet { scheduleRoute() } }
    @Published private(set) var actionsSourceName = "built-in sample"

    // MARK: Live parameters
    @Published var minimumConfidence = 0.3 { didSet { scheduleApplyConfiguration() } }
    @Published var abstainOnAmbiguity = false { didSet { scheduleApplyConfiguration() } }
    @Published var minimumMargin = 0.08 { didSet { scheduleApplyConfiguration() } }
    @Published var maxCandidates = 8.0 { didSet { scheduleApplyConfiguration() } }
    @Published var similarityFloor = SemanticConfiguration.e5.similarityFloor {
        didSet { scheduleApplyConfiguration() }
    }
    @Published var similarityCeiling = SemanticConfiguration.e5.similarityCeiling {
        didSet { scheduleApplyConfiguration() }
    }
    @Published var agreementBonus = SemanticConfiguration.e5.agreementBonus {
        didSet { scheduleApplyConfiguration() }
    }

    // MARK: Outputs
    @Published private(set) var result: RoutingResult?
    @Published private(set) var semanticStatus: SemanticTierStatus = .disabled
    @Published private(set) var isPreparingProvider = false
    @Published private(set) var e5Available = false
    @Published private(set) var loadError: String?

    private var router: ActionRouter?
    private var routeTask: Task<Void, Never>?
    private var configTask: Task<Void, Never>?
    private var routeGeneration = 0

    let e5Directory: URL

    init() {
        // Default to the conversion output when running from the repo root.
        e5Directory = URL(fileURLWithPath: "tools/convert/build", isDirectory: true)
        e5Available = FileManager.default.fileExists(
            atPath: e5Directory.appendingPathComponent("MultilingualE5Small-Int8.mlpackage").path
        )
        actions = Self.builtInActions
        enabledIDs = Set(actions.map(\.id))
        if e5Available { providerChoice = .e5 } else { rebuildRouter() }
    }

    // MARK: - Router lifecycle

    private func currentConfiguration() -> RouterConfiguration {
        var configuration = RouterConfiguration()
        configuration.abstention.minimumConfidence = minimumConfidence
        configuration.abstention.abstainOnAmbiguity = abstainOnAmbiguity
        configuration.abstention.minimumMargin = minimumMargin
        configuration.maxCandidates = Int(maxCandidates)
        var semantic: SemanticConfiguration
        switch providerChoice {
        case .apple: semantic = .appleNaturalLanguage
        default: semantic = .e5
        }
        semantic.similarityFloor = similarityFloor
        semantic.similarityCeiling = similarityCeiling
        semantic.agreementBonus = agreementBonus
        configuration.semantic = semantic
        return configuration
    }

    private func makeProvider() -> (any EmbeddingProvider)? {
        switch providerChoice {
        case .lexical:
            return nil
        case .apple:
            return NaturalLanguageEmbeddingProvider()
        case .e5:
            return CoreMLEmbeddingProvider(
                modelURL: e5Directory.appendingPathComponent("MultilingualE5Small-Int8.mlpackage"),
                tokenizerDirectory: e5Directory.appendingPathComponent("tokenizer")
            )
        }
    }

    func rebuildRouter() {
        let configuration = currentConfiguration()
        let provider = makeProvider()
        let actions = self.actions
        isPreparingProvider = provider != nil
        routeTask?.cancel()
        Task {
            let router = ActionRouter(configuration: configuration, embeddingProvider: provider)
            await router.register(actions)
            self.router = router
            self.semanticStatus = await router.semanticStatus
            self.isPreparingProvider = false
            self.scheduleRoute(debounce: false)
        }
    }

    private func scheduleApplyConfiguration() {
        configTask?.cancel()
        configTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let router else { return }
            await router.updateConfiguration(currentConfiguration())
            semanticStatus = await router.semanticStatus
            scheduleRoute(debounce: false)
        }
    }

    // MARK: - Routing

    func scheduleRoute(debounce: Bool = true) {
        routeTask?.cancel()
        routeGeneration += 1
        let generation = routeGeneration
        let query = self.query
        let hints = contextHints
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let allowed = enabledIDs
        routeTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard !Task.isCancelled, let router else { return }
            let context = RoutingContext(hints: hints, allowedActionIDs: allowed)
            guard let routed = try? await router.route(query, context: context) else { return }
            guard generation == routeGeneration else { return }
            result = routed
            semanticStatus = await router.semanticStatus
        }
    }

    // MARK: - Action sets

    func loadActions(from url: URL) {
        do {
            let loaded = try JSONDecoder().decode([Action].self, from: Data(contentsOf: url))
            actions = loaded
            enabledIDs = Set(loaded.map(\.id))
            actionsSourceName = url.lastPathComponent
            loadError = nil
            rebuildRouter()
        } catch {
            loadError = "Could not load \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func resetActions() {
        actions = Self.builtInActions
        enabledIDs = Set(actions.map(\.id))
        actionsSourceName = "built-in sample"
        rebuildRouter()
    }

    static let builtInActions: [Action] = [
        Action(
            id: "audio-to-wav", name: "Convert audio to WAV",
            description: "Converts audio files to the WAV format.",
            keywords: ["wav", "audio", "convert", "format"],
            examples: ["convert this song to wav", "make this file a wav"],
            metadata: ["inputFormats": "mp3 aac flac ogg m4a"]
        ),
        Action(
            id: "audio-to-mp3", name: "Convert audio to MP3",
            description: "Converts audio files to the MP3 format.",
            keywords: ["mp3", "audio", "convert", "format"],
            examples: ["convert to mp3", "make this an mp3"],
            metadata: ["inputFormats": "wav aac flac ogg m4a"]
        ),
        Action(
            id: "trim-audio", name: "Trim audio",
            description: "Cuts a section out of an audio file.",
            keywords: ["trim", "cut", "audio", "clip"],
            examples: ["cut the first 10 seconds", "trim this song", "cut this mp3"],
            metadata: ["inputFormats": "mp3 wav aac flac ogg m4a"]
        ),
        Action(
            id: "compress-video", name: "Compress video",
            description: "Reduces the file size of a video.",
            keywords: ["video", "compress", "smaller", "size"],
            examples: ["make this video smaller", "shrink the video"],
            metadata: ["inputFormats": "mp4 mov avi mkv"]
        ),
        Action(
            id: "extract-frames", name: "Extract video frames",
            description: "Saves individual frames of a video as images.",
            keywords: ["frames", "screenshot", "video", "extract", "still"],
            examples: ["get a frame from this video", "extract images from video"]
        ),
        Action(
            id: "remove-background", name: "Remove image background",
            description: "Removes the background from a picture.",
            keywords: ["background", "image", "transparent", "png"],
            examples: ["remove the background from this photo", "make background transparent"]
        ),
        Action(
            id: "resize-image", name: "Resize image",
            description: "Changes the dimensions of an image.",
            keywords: ["resize", "scale", "image", "dimensions"],
            examples: ["make this image 1024 pixels wide", "scale down this photo"]
        ),
        Action(
            id: "merge-pdf", name: "Merge PDF documents",
            description: "Combines several PDF files into one.",
            keywords: ["pdf", "merge", "combine", "join"],
            examples: ["combine these pdfs", "join pdf files"]
        ),
    ]
}
