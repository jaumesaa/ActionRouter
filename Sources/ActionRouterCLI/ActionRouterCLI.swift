import ActionRouter
import ActionRouterCoreML
import ArgumentParser
import Foundation

@main
struct ActionRouterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "actionrouter",
        abstract: "On-device dynamic intent routing: match a natural-language request to the best action.",
        version: "0.1.0",
        subcommands: [Route.self, Eval.self, FetchModel.self],
        defaultSubcommand: Route.self
    )
}

struct RouteOptions: ParsableArguments {
    @Option(name: [.short, .long], help: "Path to a JSON file with the available actions.")
    var actions: String

    @Option(name: [.short, .long], help: "Context hint (repeatable), e.g. -c mp3 -c audio.")
    var context: [String] = []

    @Option(name: [.short, .long], help: "Maximum candidates to show.")
    var top: Int = 5

    @Flag(name: .long, help: "Emit machine-readable JSON instead of a table.")
    var json = false

    @Flag(name: .long, help: "Show the full per-signal score breakdown.")
    var explain = false

    @Flag(name: .long, help: "Enable the semantic tier (Apple NLContextualEmbedding).")
    var semantic = false

    @Option(name: .long, help: """
    Enable the semantic tier with a converted E5 Core ML model. Pass the \
    directory produced by tools/convert/convert_e5.py (contains \
    MultilingualE5Small.mlpackage and tokenizer/).
    """)
    var e5Dir: String?
}

/// Finds the model package inside a directory produced by `fetch-model` or
/// `tools/convert` (any .mlpackage; the int8 variant is preferred).
func resolveModelPackage(in directory: URL) throws -> URL {
    let packages = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    ))?.filter { $0.pathExtension == "mlpackage" } ?? []
    if let int8 = packages.first(where: { $0.lastPathComponent.contains("Int8") }) {
        return int8
    }
    guard let first = packages.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
        throw ValidationError("No .mlpackage found in \(directory.path)")
    }
    return first
}

struct Route: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Route a query against a JSON action set."
    )

    @OptionGroup var options: RouteOptions

    @Argument(help: "The natural-language request, e.g. \"convertir a wav\".")
    var query: String

    func run() async throws {
        let url = URL(fileURLWithPath: options.actions)
        let data = try Data(contentsOf: url)
        let actions = try JSONDecoder().decode([Action].self, from: data)

        var configuration = RouterConfiguration.default
        configuration.maxCandidates = options.top

        let provider: (any EmbeddingProvider)?
        if let e5Dir = options.e5Dir {
            let directory = URL(fileURLWithPath: e5Dir, isDirectory: true)
            configuration.semantic = .e5
            provider = CoreMLEmbeddingProvider(
                modelURL: try resolveModelPackage(in: directory),
                tokenizerDirectory: directory.appendingPathComponent("tokenizer")
            )
        } else if options.semantic {
            configuration.semantic = .appleNaturalLanguage
            provider = NaturalLanguageEmbeddingProvider()
        } else {
            provider = nil
        }

        let router = ActionRouter(configuration: configuration, embeddingProvider: provider)
        await router.register(actions)

        if provider != nil {
            let status = await router.semanticStatus
            if case .unavailable(let reason) = status {
                FileHandle.standardError.write(Data(
                    "WARNING: semantic tier unavailable (\(reason)); lexical-only.\n".utf8
                ))
            }
        }

        let routingContext = options.context.isEmpty
            ? nil
            : RoutingContext(hints: options.context)
        let result = try await router.route(query, context: routingContext)

        if options.json {
            try printJSON(result)
        } else {
            printTable(result, explain: options.explain)
        }
    }

    private func printTable(_ result: RoutingResult, explain: Bool) {
        switch result.decision {
        case .matched(let match):
            print("MATCH: \(match.action.name) [\(match.action.id)]")
            print(String(format: "  confidence: %.3f", match.confidence))
        case .abstained(let reason):
            print("ABSTAINED: \(describe(reason))")
        }
        print(String(format: "  duration: %.2f ms", milliseconds(result.duration)))

        guard !result.candidates.isEmpty else { return }
        print("\nCandidates:")
        for (rank, candidate) in result.candidates.enumerated() {
            print(String(
                format: "  %d. %-38s conf=%.3f fused=%.3f",
                rank + 1,
                (candidate.action.name as NSString).utf8String ?? "",
                candidate.confidence,
                candidate.fusedScore
            ))
            if explain {
                for (signal, value) in candidate.signals.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    print(String(format: "       %-28s %.3f", (signal.rawValue as NSString).utf8String ?? "", value))
                }
            }
        }
    }

    private func describe(_ reason: AbstentionReason) -> String {
        switch reason {
        case .emptyQuery:
            return "empty query"
        case .noActionsRegistered:
            return "no actions registered"
        case .insufficientConfidence(let best, let required):
            return String(format: "no suitable action (best confidence %.3f < required %.3f)", best, required)
        case .ambiguous(let margin, let required):
            return String(format: "ambiguous (margin %.3f < required %.3f)", margin, required)
        }
    }

    private func printJSON(_ result: RoutingResult) throws {
        struct CandidateOutput: Encodable {
            let id: String
            let name: String
            let confidence: Double
            let fusedScore: Double
            let signals: [String: Double]
        }
        struct Output: Encodable {
            let query: String
            let decision: String
            let matchedActionID: String?
            let abstentionReason: String?
            let durationMilliseconds: Double
            let candidates: [CandidateOutput]
        }

        let matched: String?
        let abstention: String?
        switch result.decision {
        case .matched(let match):
            matched = match.action.id
            abstention = nil
        case .abstained(let reason):
            matched = nil
            abstention = describe(reason)
        }

        let output = Output(
            query: result.query,
            decision: matched != nil ? "matched" : "abstained",
            matchedActionID: matched,
            abstentionReason: abstention,
            durationMilliseconds: milliseconds(result.duration),
            candidates: result.candidates.map { candidate in
                CandidateOutput(
                    id: candidate.action.id,
                    name: candidate.action.name,
                    confidence: candidate.confidence,
                    fusedScore: candidate.fusedScore,
                    signals: Dictionary(
                        uniqueKeysWithValues: candidate.signals.map { ($0.key.rawValue, $0.value) }
                    )
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }
}
