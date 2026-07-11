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

Everything runs in-process and offline: no server, no telemetry, and
queries never leave the device. Actions are plain data that you register
and remove at runtime (plugins, user settings, app state) — there is no
training step, so previously unseen actions route immediately. When
nothing fits, the router abstains with a reason instead of returning the
least-wrong option, and every result carries the full ranked list with
per-signal scores so you can see exactly why it decided what it did.

Routing is fast enough to run on every keystroke of a Spotlight-style
panel: about 1 ms per query with the lexical tier, about 9 ms with the
multilingual semantic tier enabled (Apple Silicon, 150 registered
actions).

Confidence values are calibrated probabilities, not raw similarity
scores — a match with `confidence == 0.7` is right about 70% of the time
on the benchmark suites. Accuracy, abstention behaviour, latency and the
measured limitations are documented in [docs/benchmarks.md](docs/benchmarks.md);
the reasoning behind the architecture (and what was tried and rejected)
is in [docs/architecture-decision.md](docs/architecture-decision.md).

The API will keep moving until 1.0; breaking changes are listed in the
[changelog](CHANGELOG.md).

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
