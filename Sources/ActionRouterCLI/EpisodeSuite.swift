import ActionRouter
import Foundation

/// A reproducible evaluation suite: a catalog of actions plus routing
/// episodes referencing subsets of it. Produced by
/// `tools/dataprep/build_episodes.py`.
struct EpisodeSuite: Decodable {
    struct Episode: Decodable {
        /// The user query to route.
        let query: String
        /// IDs (into `actions`) available for this episode.
        let actions: [String]
        /// Expected action ID, or nil when the correct behaviour is to
        /// abstain (out-of-scope query, or gold intentionally absent).
        let gold: String?
        /// BCP-47-ish language tag of the query (e.g. "en", "ca").
        let language: String
        /// Perturbation/condition tags, e.g. ["typo"], ["absent"].
        let tags: [String]
    }

    let suite: String
    let source: String
    let license: String
    let seed: Int
    let actions: [Action]
    let episodes: [Episode]

    static func load(from url: URL) throws -> EpisodeSuite {
        try JSONDecoder().decode(EpisodeSuite.self, from: Data(contentsOf: url))
    }
}

/// One routed episode, flattened for aggregation and CSV/JSON export.
struct EvalRecord: Encodable {
    let suite: String
    let language: String
    let tags: [String]
    let actionCount: Int
    let goldPresent: Bool
    /// Router returned .matched (vs abstained).
    let matched: Bool
    /// Top-ranked candidate equals gold (ranking view, ignores abstention).
    let top1Correct: Bool
    /// 1-based rank of gold among candidates; nil if gold absent or unranked.
    let goldRank: Int?
    let bestConfidence: Double
    let durationMilliseconds: Double
}
