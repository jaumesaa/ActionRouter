import ActionRouter
import ActionRouterCoreML
import Foundation

// Demonstration: adapting AnyAction's tool catalog to ActionRouter.
//
// `ToolDefinition` below mirrors the fields of AnyAction's real type
// (AnyAction/ToolRegistry/ToolDefinition.swift) that matter for routing.
// In the real app you would write the same `Action(tool:)` mapping as an
// extension on the real type — the router core never learns about
// AnyAction.

struct ToolDefinition {
    let id: String
    let name: String
    let category: String
    let description: String
    let usageExamples: [String]
    let inputFormats: [String]
    let outputFormats: [String]
    var isEnabled: Bool = true
}

extension Action {
    /// The adapter: every routing-relevant ToolDefinition field has a
    /// natural home in `Action`. Input formats go into metadata so a
    /// query mentioning the *object* ("cortar mp3") supports tools that
    /// accept mp3, and into keywords with low noise via metadata weight.
    init(tool: ToolDefinition) {
        self.init(
            id: tool.id,
            name: tool.name,
            description: tool.description,
            keywords: tool.outputFormats,
            examples: tool.usageExamples,
            metadata: [
                "inputFormats": tool.inputFormats.joined(separator: " "),
                "category": tool.category,
            ]
        )
    }
}

/// What AnyAction knows at invocation time that the router cannot:
/// the files the user right-clicked. Applicability is categorical, so it
/// becomes a hard filter; the file type is a soft hint.
func routingContext(
    selectedExtensions: [String], tools: [ToolDefinition]
) -> RoutingContext {
    let applicable = tools.filter { tool in
        tool.isEnabled && (
            tool.inputFormats.isEmpty
                || !Set(tool.inputFormats).isDisjoint(with: selectedExtensions)
        )
    }
    return RoutingContext(
        hints: selectedExtensions,
        allowedActionIDs: Set(applicable.map(\.id))
    )
}

// A slice of AnyAction's real native catalog (ToolRegistryManager.swift).
let catalog: [ToolDefinition] = [
    ToolDefinition(
        id: "trim-audio", name: "Trim Audio", category: "audio",
        description: "Cut and trim audio files with waveform preview. Supports all audio formats.",
        usageExamples: [
            "Extract a 30-second clip from a podcast",
            "Trim a voice recording preserving original quality",
            "Cut a section from an mp3 track",
        ],
        inputFormats: ["mp3", "m4a", "wav", "flac", "ogg", "aac", "aiff"],
        outputFormats: ["mp3", "m4a", "wav", "flac"]
    ),
    ToolDefinition(
        id: "merge-audio", name: "Merge Audio Files", category: "audio",
        description: "Combine multiple audio files into a single file.",
        usageExamples: [
            "Merge podcast segments into one episode",
            "Join interview recordings together",
        ],
        inputFormats: ["mp3", "m4a", "wav", "flac", "ogg", "aac"],
        outputFormats: ["mp3", "m4a", "wav"]
    ),
    ToolDefinition(
        id: "transcribe-audio", name: "Transcribir Audio", category: "audio",
        description: "Convert audio speech to text transcription.",
        usageExamples: [
            "Transcribe interview recordings to text",
            "Convert voice memos to written notes",
            "Generate subtitles from audio narration",
        ],
        inputFormats: ["mp3", "m4a", "wav", "flac", "ogg"],
        outputFormats: ["txt", "srt"]
    ),
    ToolDefinition(
        id: "compress-video", name: "Compress Video", category: "video",
        description: "Reduce video file size while preserving quality.",
        usageExamples: [
            "Compress a screen recording before sharing",
            "Make a phone video small enough to email",
            "Make this video smaller",
            "Reduce how much space the video takes",
        ],
        inputFormats: ["mp4", "mov", "avi", "mkv"],
        outputFormats: ["mp4"]
    ),
    ToolDefinition(
        id: "extract-frames", name: "Extract Video Frames", category: "video",
        description: "Save individual frames of a video as images.",
        usageExamples: [
            "Grab a still from a video",
            "Export frames as PNG images",
        ],
        inputFormats: ["mp4", "mov", "avi", "mkv"],
        outputFormats: ["png", "jpg"]
    ),
    ToolDefinition(
        id: "video-to-gif", name: "Video to GIF", category: "video",
        description: "Convert video clips into animated GIFs.",
        usageExamples: [
            "Turn a short clip into a GIF",
            "Make a reaction gif from a video",
        ],
        inputFormats: ["mp4", "mov", "avi"],
        outputFormats: ["gif"]
    ),
    ToolDefinition(
        id: "compress-image", name: "Compress Image", category: "image",
        description: "Reduce image file size.",
        usageExamples: [
            "Shrink photos before uploading",
            "Reduce a png's size on disk",
        ],
        inputFormats: ["png", "jpg", "jpeg", "heic", "webp"],
        outputFormats: ["png", "jpg", "webp"]
    ),
    ToolDefinition(
        id: "resize-image", name: "Resize Image", category: "image",
        description: "Change the dimensions of an image.",
        usageExamples: [
            "Make this image 1024 pixels wide",
            "Scale down a photo",
        ],
        inputFormats: ["png", "jpg", "jpeg", "heic", "webp"],
        outputFormats: ["png", "jpg"]
    ),
    ToolDefinition(
        id: "ai-erase-object", name: "AI Erase Object", category: "image",
        description: "Remove objects or backgrounds from photos using on-device AI.",
        usageExamples: [
            "Remove a person from the background",
            "Erase an unwanted object from a photo",
            "Remove the background of a picture",
        ],
        inputFormats: ["png", "jpg", "jpeg", "heic"],
        outputFormats: ["png"]
    ),
    ToolDefinition(
        id: "merge-pdf", name: "Merge PDFs", category: "pdf",
        description: "Combine several PDF documents into one file.",
        usageExamples: [
            "Combine scanned pages into a single pdf",
            "Join invoices into one document",
        ],
        inputFormats: ["pdf"],
        outputFormats: ["pdf"]
    ),
]

@main
struct AnyActionAdapterDemo {
    static func main() async throws {
        // Use the converted model when present (run from the repo root),
        // otherwise demonstrate lexical-only routing.
        let e5Directory = URL(fileURLWithPath: "tools/convert/build", isDirectory: true)
        let hasModel = FileManager.default.fileExists(
            atPath: e5Directory.appendingPathComponent("MultilingualE5Small-Int8.mlpackage").path
        )
        var configuration = RouterConfiguration.default
        configuration.semantic = .e5
        let provider: (any EmbeddingProvider)? = hasModel
            ? CoreMLEmbeddingProvider(
                modelURL: e5Directory.appendingPathComponent("MultilingualE5Small-Int8.mlpackage"),
                tokenizerDirectory: e5Directory.appendingPathComponent("tokenizer")
            )
            : nil
        print("backend: \(hasModel ? "lexical + e5 semantic" : "lexical only (model not found)")\n")

        let router = ActionRouter(configuration: configuration, embeddingProvider: provider)
        await router.register(catalog.map(Action.init(tool:)))

        // Each scenario: (what the user right-clicked, what they typed).
        let scenarios: [(extensions: [String], query: String)] = [
            (["mp3"], "cortar mp3"),                  // object, not target format
            (["mp3"], "passa-ho a text"),             // Catalan, cross-language
            (["mov"], "quiero que pese menos"),       // Spanish paraphrase
            (["png"], "treu el fons de la foto"),     // Catalan
            (["mp4"], "fes un gif"),
            (["pdf"], "ajunta aquests documents"),
            // Requesting a capability that is not available (image
            // conversion for an mp3) SHOULD abstain. This is the router's
            // documented weak spot — embeddings may still pick the nearest
            // available action with modest confidence. See the "gold
            // absent" rows in docs/benchmarks.md; raise
            // `abstention.minimumConfidence` if this matters in your app.
            (["mp3"], "convert to jpg"),
        ]

        for scenario in scenarios {
            let context = routingContext(
                selectedExtensions: scenario.extensions, tools: catalog
            )
            let result = try await router.route(scenario.query, context: context)
            let outcome: String
            switch result.decision {
            case .matched(let match):
                outcome = "\(match.action.name)  (P=\(String(format: "%.2f", match.confidence)))"
            case .abstained:
                outcome = "ABSTAINED — closest: \(result.candidates.first?.action.name ?? "-")"
            }
            print("[\(scenario.extensions.joined(separator: ","))] \"\(scenario.query)\" -> \(outcome)")
        }
    }
}
