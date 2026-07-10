import ActionRouter
import ActionRouterCoreML
import ArgumentParser
import Foundation

struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run episode suites and report accuracy, abstention, latency and memory metrics."
    )

    @Argument(help: "Episode suite JSON files, or directories containing them.")
    var paths: [String]

    @Flag(name: .long, help: "Enable the semantic tier (Apple NLContextualEmbedding).")
    var semantic = false

    @Option(name: .long, help: "Enable the semantic tier with a converted E5 Core ML model directory.")
    var e5Dir: String?

    @Option(name: .long, help: "Model package filename inside --e5-dir (e.g. MultilingualE5Small-Int8.mlpackage).")
    var e5Model = "MultilingualE5Small.mlpackage"

    @Option(name: .long, help: "Override the abstention confidence threshold.")
    var minConfidence: Double?

    @Option(name: .long, help: "Evaluate at most this many episodes per suite (smoke runs).")
    var maxEpisodes: Int?

    @Option(name: .long, help: "Write per-episode records and aggregates as JSON.")
    var jsonOut: String?

    func run() async throws {
        let suiteURLs = try resolveSuiteURLs()
        guard !suiteURLs.isEmpty else {
            throw ValidationError("No episode suite JSON files found in: \(paths.joined(separator: ", "))")
        }

        var allRecords: [EvalRecord] = []
        var suiteSummaries: [SuiteSummary] = []

        for url in suiteURLs {
            let suite = try EpisodeSuite.load(from: url)
            let (records, registerMs, coldMs) = try await run(suite: suite)
            allRecords.append(contentsOf: records)
            let summary = SuiteSummary(
                suite: suite.suite,
                records: records,
                registerMilliseconds: registerMs,
                coldRouteMilliseconds: coldMs
            )
            suiteSummaries.append(summary)
            print(summary.render())
        }

        print(renderCrossSuite(records: allRecords))
        print(renderRiskCoverage(records: allRecords))
        print(renderResources())

        if let jsonOut {
            try writeJSON(to: jsonOut, records: allRecords, summaries: suiteSummaries)
            print("\nwrote JSON report to \(jsonOut)")
        }
    }

    // MARK: - Execution

    private func run(
        suite: EpisodeSuite
    ) async throws -> (records: [EvalRecord], registerMs: Double, coldMs: Double) {
        var configuration = RouterConfiguration.default
        // Rank all candidates so gold rank / MRR are exact.
        configuration.maxCandidates = suite.actions.count
        if let minConfidence {
            configuration.abstention.minimumConfidence = minConfidence
        }

        let provider: (any EmbeddingProvider)?
        if let e5Dir {
            let directory = URL(fileURLWithPath: e5Dir, isDirectory: true)
            configuration.semantic = .e5
            provider = CoreMLEmbeddingProvider(
                modelURL: directory.appendingPathComponent(e5Model),
                tokenizerDirectory: directory.appendingPathComponent("tokenizer")
            )
        } else if semantic {
            configuration.semantic = .appleNaturalLanguage
            provider = NaturalLanguageEmbeddingProvider()
        } else {
            provider = nil
        }

        let router = ActionRouter(configuration: configuration, embeddingProvider: provider)

        let clock = ContinuousClock()
        let registerStart = clock.now
        await router.register(suite.actions)
        let registerMs = milliseconds(clock.now - registerStart)

        if provider != nil {
            let status = await router.semanticStatus
            if case .unavailable(let reason) = status {
                throw ValidationError("Semantic tier unavailable: \(reason)")
            }
        }

        let episodes = maxEpisodes.map { Array(suite.episodes.prefix($0)) } ?? suite.episodes
        var records: [EvalRecord] = []
        records.reserveCapacity(episodes.count)
        var coldMs = 0.0

        for (index, episode) in episodes.enumerated() {
            let context = RoutingContext(allowedActionIDs: Set(episode.actions))
            let result = try await router.route(episode.query, context: context)
            let ms = milliseconds(result.duration)
            if index == 0 { coldMs = ms }

            let goldRank = episode.gold.flatMap { gold in
                result.candidates.firstIndex { $0.action.id == gold }.map { $0 + 1 }
            }
            let best = result.candidates.first
            let runnerUp = result.candidates.dropFirst().first
            records.append(EvalRecord(
                suite: suite.suite,
                language: episode.language,
                tags: episode.tags,
                actionCount: episode.actions.count,
                goldPresent: episode.gold != nil,
                matched: result.match != nil,
                top1Correct: episode.gold != nil
                    && best?.action.id == episode.gold,
                goldRank: goldRank,
                bestConfidence: best?.confidence ?? 0,
                bestFusedScore: best?.fusedScore ?? 0,
                fusedMargin: (best?.fusedScore ?? 0) - (runnerUp?.fusedScore ?? 0),
                bestSemanticCosine: best?.signals[.semanticCosine],
                durationMilliseconds: ms
            ))
            if (index + 1) % 200 == 0 {
                FileHandle.standardError.write(Data(
                    "  \(suite.suite): \(index + 1)/\(episodes.count)\n".utf8
                ))
            }
        }
        return (records, registerMs, coldMs)
    }

    // MARK: - Reporting

    private func renderCrossSuite(records: [EvalRecord]) -> String {
        var out = "\n=== By language (in-scope episodes) ===\n"
        out += Aggregates.table(
            of: records.filter(\.goldPresent),
            groupedBy: { $0.language }
        )
        out += "\n=== By action-set size (in-scope episodes) ===\n"
        out += Aggregates.table(
            of: records.filter(\.goldPresent),
            groupedBy: { String(format: "N=%3d", $0.actionCount) }
        )
        out += "\n=== By tag ===\n"
        out += Aggregates.table(
            of: records,
            groupedBy: { $0.tags.isEmpty ? "(none)" : $0.tags.joined(separator: "+") }
        )
        return out
    }

    private func renderRiskCoverage(records: [EvalRecord]) -> String {
        // Post-hoc threshold sweep over the top candidate's confidence:
        // "answer" iff confidence >= t; an answer is an error if the gold is
        // absent (should have abstained) or the top-1 is wrong.
        var out = "\n=== Risk-coverage (confidence threshold sweep) ===\n"
        out += "thresh  coverage  errorRate(answered)  abstainAcc(OOS)\n"
        let oos = records.filter { !$0.goldPresent }
        for threshold in stride(from: 0.0, through: 0.9, by: 0.1) {
            let answered = records.filter { $0.bestConfidence >= threshold }
            let errors = answered.filter { !$0.goldPresent || !$0.top1Correct }
            let coverage = Double(answered.count) / Double(max(1, records.count))
            let risk = Double(errors.count) / Double(max(1, answered.count))
            let oosCorrect = oos.filter { $0.bestConfidence < threshold }
            let oosAccuracy = Double(oosCorrect.count) / Double(max(1, oos.count))
            out += String(
                format: "%.2f    %6.1f%%  %8.1f%%             %6.1f%%\n",
                threshold, coverage * 100, risk * 100, oosAccuracy * 100
            )
        }
        return out
    }

    private func renderResources() -> String {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let peakMB = Double(usage.ru_maxrss) / (1024 * 1024)
        return String(format: "\npeak RSS: %.0f MB\n", peakMB)
    }

    private func writeJSON(
        to path: String, records: [EvalRecord], summaries: [SuiteSummary]
    ) throws {
        struct Report: Encodable {
            let generatedAt: String
            let configuration: [String: String]
            let summaries: [SuiteSummary.Snapshot]
            let records: [EvalRecord]
        }
        let report = Report(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            configuration: [
                "provider": e5Dir != nil ? "coreml-e5" : (semantic ? "apple-nl" : "lexical-only"),
                "minConfidence": minConfidence.map { String($0) } ?? "default",
            ],
            summaries: summaries.map(\.snapshot),
            records: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: path))
    }

    private func resolveSuiteURLs() throws -> [URL] {
        var urls: [URL] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw ValidationError("No such file or directory: \(path)")
            }
            if isDirectory.boolValue {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil
                )
                urls.append(contentsOf: contents.filter { $0.pathExtension == "json" })
            } else {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Aggregation

struct SuiteSummary {
    struct Snapshot: Encodable {
        let suite: String
        let episodes: Int
        let endToEndAccuracy: Double?
        let rankingAccuracy: Double?
        let mrr: Double?
        let falseAbstainRate: Double?
        let abstainAccuracy: Double?
        let warmP50Milliseconds: Double
        let warmP95Milliseconds: Double
        let registerMilliseconds: Double
        let coldRouteMilliseconds: Double
    }

    let suite: String
    let records: [EvalRecord]
    let registerMilliseconds: Double
    let coldRouteMilliseconds: Double

    var snapshot: Snapshot {
        let inScope = records.filter(\.goldPresent)
        let outOfScope = records.filter { !$0.goldPresent }
        let warm = records.dropFirst(3).map(\.durationMilliseconds).sorted()

        return Snapshot(
            suite: suite,
            episodes: records.count,
            endToEndAccuracy: inScope.isEmpty ? nil
                : ratio(inScope.filter { $0.matched && $0.top1Correct }.count, inScope.count),
            rankingAccuracy: inScope.isEmpty ? nil
                : ratio(inScope.filter(\.top1Correct).count, inScope.count),
            mrr: inScope.isEmpty ? nil
                : inScope.map { $0.goldRank.map { 1.0 / Double($0) } ?? 0 }
                    .reduce(0, +) / Double(inScope.count),
            falseAbstainRate: inScope.isEmpty ? nil
                : ratio(inScope.filter { !$0.matched }.count, inScope.count),
            abstainAccuracy: outOfScope.isEmpty ? nil
                : ratio(outOfScope.filter { !$0.matched }.count, outOfScope.count),
            warmP50Milliseconds: percentile(warm, 0.5),
            warmP95Milliseconds: percentile(warm, 0.95),
            registerMilliseconds: registerMilliseconds,
            coldRouteMilliseconds: coldRouteMilliseconds
        )
    }

    func render() -> String {
        let s = snapshot
        var out = "\n=== \(suite) (\(s.episodes) episodes) ===\n"
        if let accuracy = s.endToEndAccuracy, let ranking = s.rankingAccuracy,
           let mrr = s.mrr, let falseAbstain = s.falseAbstainRate {
            out += String(
                format: "in-scope: end-to-end %.1f%% | ranking %.1f%% | MRR %.3f | false-abstain %.1f%%\n",
                accuracy * 100, ranking * 100, mrr, falseAbstain * 100
            )
        }
        if let abstain = s.abstainAccuracy {
            out += String(format: "out-of-scope: correct abstention %.1f%%\n", abstain * 100)
        }
        out += String(
            format: "latency: register %.0f ms | cold route %.1f ms | warm p50 %.2f ms | p95 %.2f ms\n",
            s.registerMilliseconds, s.coldRouteMilliseconds,
            s.warmP50Milliseconds, s.warmP95Milliseconds
        )
        return out
    }
}

enum Aggregates {
    static func table(
        of records: [EvalRecord], groupedBy key: (EvalRecord) -> String
    ) -> String {
        let groups = Dictionary(grouping: records, by: key)
        var out = "group         n     e2e-acc  ranking  false-abst/abst-acc\n"
        for (group, groupRecords) in groups.sorted(by: { $0.key < $1.key }) {
            let inScope = groupRecords.filter(\.goldPresent)
            let outOfScope = groupRecords.filter { !$0.goldPresent }
            let e2e = inScope.isEmpty ? Double.nan
                : ratio(inScope.filter { $0.matched && $0.top1Correct }.count, inScope.count)
            let ranking = inScope.isEmpty ? Double.nan
                : ratio(inScope.filter(\.top1Correct).count, inScope.count)
            let lastColumn: Double
            if !outOfScope.isEmpty {
                lastColumn = ratio(outOfScope.filter { !$0.matched }.count, outOfScope.count)
            } else if !inScope.isEmpty {
                lastColumn = ratio(inScope.filter { !$0.matched }.count, inScope.count)
            } else {
                lastColumn = .nan
            }
            out += String(
                format: "%-12s %5d  %6.1f%%  %6.1f%%  %6.1f%%\n",
                (group as NSString).utf8String ?? "", groupRecords.count,
                e2e * 100, ranking * 100, lastColumn * 100
            )
        }
        return out
    }
}

private func ratio(_ numerator: Int, _ denominator: Int) -> Double {
    denominator == 0 ? 0 : Double(numerator) / Double(denominator)
}

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = Int(Double(sorted.count - 1) * p)
    return sorted[index]
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000
        + Double(duration.components.attoseconds) / 1e15
}
