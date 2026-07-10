# ActionRouter

**On-device dynamic intent routing for Swift.** Give it a short natural-language
request and a list of available actions; get back the most appropriate action,
a confidence assessment, ranked alternatives — or an explicit decision that
none of the actions fit.

```swift
import ActionRouter

let router = ActionRouter()
await router.register([
    Action(id: "wav", name: "Convert audio to WAV"),
    Action(id: "bg", name: "Remove image background"),
])

let result = try await router.route("convertir a wav")
switch result.decision {
case .matched(let match):
    print("\(match.action.name) (confidence \(match.confidence))")
case .abstained(let reason):
    print("No suitable action: \(reason)")
}
```

- **Fully local.** No network, no telemetry, sandbox-friendly. Queries never
  leave the device.
- **Dynamic actions.** Register and remove actions at any time — from plugins,
  user configuration, or app state. No training step, ever.
- **Honest abstention.** The router says "none of these" instead of returning
  the least-wrong option, with configurable thresholds.
- **Interactive-fast.** Designed for as-you-type UI (Spotlight-style panels).
- **Diagnosable.** Every result carries ranked candidates and per-signal score
  breakdowns.

## Status

Pre-release, under active development. Current state:

| Piece | Status |
| --- | --- |
| Core API (`Action`, `ActionRouter`, abstention, context) | Implemented |
| Lexical tier (exact / prefix / fuzzy / BM25 / keywords) | Implemented |
| Semantic tier: Core ML `multilingual-e5-small` provider + conversion tooling | Implemented — recommended (int8, 113 MB; `ActionRouterCoreML`, `tools/convert`) |
| Semantic tier: Apple `NLContextualEmbedding` provider (zero download) | Implemented — measured too weak for production, see `docs/architecture-decision.md` |
| Reproducible benchmark harness (5,350 episodes from CLINC-150 / Banking77 / MASSIVE) | Implemented (`Benchmarks/`, `actionrouter eval`) |
| Calibrated confidence (logistic fit on dev suites; ECE ≤ 0.033) | Implemented (`docs/benchmarks.md`) |
| Playground app (live decision visualization) | Implemented (`swift run RouterPlayground`) |

The public API may still change before `0.1.0`.

## Installation

Swift Package Manager, macOS 14+ / iOS 17+:

```swift
.package(url: "https://github.com/jaumesaa/ActionRouter.git", from: "0.1.0")
```

For the recommended multilingual semantic tier, fetch the converted model
(113 MB + 21 MB tokenizer; MIT, converted from
[intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small)):

```sh
swift run actionrouter fetch-model --to path/to/model-dir
```

or convert it yourself, reproducibly, with `tools/convert/convert_e5.py`
(numerical parity against the reference model is verified during
conversion). Without a model, routing is lexical-only but fully
functional.

## Documentation

- [Integration guide](docs/integration-guide.md) — API, modeling actions
  well, context, abstention tuning
- [Benchmarks](docs/benchmarks.md) — frozen-test results, methodology
- [Architecture decision record](docs/architecture-decision.md) — what was
  measured, what was chosen, what was rejected
- [Privacy & security](docs/privacy.md) · [Roadmap](docs/roadmap.md) ·
  [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

## CLI

The package ships an `actionrouter` executable for experimentation:

```sh
swift run actionrouter route --actions Examples/sample-actions.json "convertir a wav" --explain
```

## Playground

A live macOS diagnostic app: type a request and watch the ranked actions,
per-signal score bars, calibrated confidence and the abstention decision
update on every keystroke. Backend, thresholds, semantic mapping and the
available action set are all adjustable live.

```sh
swift run RouterPlayground   # run from the repo root so the e5 model is auto-detected
```

## Design

ActionRouter is a tiered hybrid router:

1. **Lexical tier** — Unicode-folded exact/prefix matching, typo-tolerant
   fuzzy token matching, trigram phrase similarity, and field-weighted BM25
   over action names, keywords, examples, descriptions, and metadata.
2. **Semantic tier** — multilingual sentence embeddings of the query against
   pre-computed embeddings of action metadata, so unseen phrasings and
   cross-language requests ("treu el fons de la foto" → *Remove image
   background*) route correctly. Two built-in providers: Apple's on-OS
   `NLContextualEmbedding` (no download, weak) and a converted
   `multilingual-e5-small` Core ML model (113–224 MB, strong — see
   `tools/convert/`). Any `EmbeddingProvider` can be plugged in; if a
   provider fails, routing degrades to lexical-only and reports why.
3. **Fusion + abstention** — signals are fused into a confidence score;
   below-threshold or ambiguous results become explicit abstentions.

Architecture decisions are made against a reproducible benchmark harness
(see `docs/` as it lands) — not by assumption.

## License

MIT — see [LICENSE](LICENSE).
