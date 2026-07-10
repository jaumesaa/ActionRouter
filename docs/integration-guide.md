# Integration guide

## 1. Add the package

```swift
// Package.swift
.package(url: "https://github.com/jaumesaa/ActionRouter.git", from: "0.1.0"),
```

Two library products:

- `ActionRouter` — the core. No dependencies. Lexical routing works out of
  the box; the semantic tier activates when you pass an `EmbeddingProvider`.
- `ActionRouterCoreML` — the recommended semantic provider for a converted
  E5 Core ML model (depends on swift-transformers for tokenization).

## 2. Get the model (recommended, optional)

The multilingual model is not bundled in the repository. Either:

```sh
# download the released artifact (113 MB model + 21 MB tokenizer)
swift run actionrouter fetch-model --to ~/Library/Application\ Support/MyApp/e5

# …or convert it yourself, reproducibly:
cd tools/convert && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python convert_e5.py --int8
```

Ship it with your app (as a download or in the bundle) however suits your
size budget. Without a model, ActionRouter still routes lexically —
same-language matching, typo tolerance, no cross-language understanding.

## 3. Route

```swift
import ActionRouter
import ActionRouterCoreML

let provider = CoreMLEmbeddingProvider(
    modelURL: modelDirectory.appendingPathComponent("MultilingualE5Small-Int8.mlpackage"),
    tokenizerDirectory: modelDirectory.appendingPathComponent("tokenizer")
)
var configuration = RouterConfiguration.default
configuration.semantic = .e5   // similarity mapping measured for E5 models

let router = ActionRouter(configuration: configuration, embeddingProvider: provider)
await router.register(myActions)

let result = try await router.route(userQuery, context: context)
switch result.decision {
case .matched(let match):   perform(match.action)
case .abstained:            showAlternatives(result.candidates)
}
```

Registration embeds action metadata (a few ms per text on the first
launch); embeddings persist in a disk cache by default
(`SemanticConfiguration.diskCache`), so later launches are near-instant.
User queries are never cached.

## 4. Model your actions well

Routing quality is mostly determined by action metadata. The router only
knows the language you give it.

- **Name**: short and specific ("Convert audio to WAV").
- **Description**: one or two sentences, in natural language.
- **Keywords**: formats, synonyms, domain terms.
- **Examples**: 2-5 realistic requests. Include the *object* of the action,
  not only the verb — "cut this mp3" teaches the router that an MP3 is
  something you trim, not only something you convert to.
- **Metadata**: indexed with low weight; put supported input formats here
  (`"inputFormats": "mp3 wav flac"`).

Worked example: with a catalog where only *Convert audio to MP3* mentions
"mp3", the query **"cortar mp3"** routes to the converter — "mp3" is the
object of "cortar", but nothing says *Trim audio* accepts MP3s. Declaring
`inputFormats` on *Trim audio* and adding a "cut this mp3" example flips
the decision, with no router changes.

## 5. Use context

Your app knows things the router cannot: the current selection, the file
type, the active view. Pass them per query:

- **`RoutingContext.allowedActionIDs`** — hard filter. With an `.mp3`
  selected, exclude actions that make no sense (converting mp3 → mp3),
  and actions that do not accept the selected type. This is categorical
  knowledge; do not leave it to scoring.
- **`RoutingContext.hints`** — soft boost, e.g. `["mp3"]` for the selected
  file's type. Hints break ties toward actions indexed with those terms;
  they can never carry a match by themselves.

```swift
let context = RoutingContext(
    hints: [selection.fileExtension],
    allowedActionIDs: ids(applicableTo: selection)
)
```

## 6. Abstention and confidence

`match.confidence` is a calibrated probability (see `docs/benchmarks.md`),
so `abstention.minimumConfidence` reads as "answer only when P(correct) ≥
x". The default 0.3 favours answering (good when your UI shows ranked
alternatives anyway). Raise it if a wrong suggestion is worse than no
suggestion. `RoutingResult.candidates` always carries the ranked list with
per-signal scores for "did you mean…" UIs and debugging.

## 7. Dynamic action sets

`register`/`remove` at any time — plugins, user settings, app state. New
actions are routable immediately. Prefer `allowedActionIDs` over
re-registering when availability changes per invocation: indexes and
embeddings are reused.

## 8. Diagnose

- `RouterPlayground` (repo) — live visualization of every signal while you
  type; load your own actions JSON.
- `actionrouter route --actions your.json "query" --explain` — same
  breakdown in the terminal; `--json` for tooling.
- `actionrouter eval` — run your own episode suites against the benchmark
  harness format (see `Benchmarks/README.md`).

## Sandbox / entitlements

Everything is in-process and offline. The disk cache lives in the app
container's Caches directory. `NaturalLanguageEmbeddingProvider` may
trigger a one-time OS asset download (system-managed). No network
entitlement is required by the library itself.
