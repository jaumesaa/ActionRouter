# Architecture decision record

Status: accepted (v0.1). Evidence below; raw reports reproducible via
`Benchmarks/README.md`. Dev suites were used for all tuning; the frozen
test set was evaluated once per final configuration (see
[benchmarks.md](benchmarks.md)).

## Decision

ActionRouter is a **hybrid two-tier scorer with calibrated confidence and
explicit abstention**:

1. **Lexical tier** (always on, no models): Unicode-folded exact/prefix
   matching, typo-tolerant fuzzy token matching (bounded
   Damerau-Levenshtein), trigram phrase similarity, field-weighted BM25.
2. **Semantic tier** (optional `EmbeddingProvider`): multilingual sentence
   embeddings of the query vs. pre-computed action-metadata embeddings.
   Recommended provider: **converted `multilingual-e5-small` Core ML model,
   int8-quantized (113 MB)**. Fusion: `max(lexical, semantic)` plus a small
   agreement bonus — either kind of evidence alone can carry a match.
3. **Confidence** is a logistic model over (fused score, top-2 margin),
   fitted per routing mode on the dev suites — a calibrated probability
   (ECE 0.025 lexical / 0.033 semantic), not a raw similarity. Abstention
   is a threshold on that probability (default 0.3, the dev optimum for
   overall decision accuracy).

Actions are dynamic: registering computes lexical indexes and embeddings
immediately (cached by content); nothing is ever trained per action set.

## Alternatives considered, with evidence

### Trained intent classifiers (Rasa/Snips-style)
Rejected without benchmarking: they require training on a fixed label set,
violating the core requirement (plugins/users add actions at runtime).

### Pure lexical routing
Strong within-language, useless across languages: dev ranking accuracy
74.0% (CLINC in-scope, N=25) but **22.0% on multilingual episodes**; e.g.
Catalan "treu el fons de la foto" cannot match "Remove image background".
Kept as the always-on tier: it is microsecond-fast, catches
format/abbreviation queries embeddings miss, and is the graceful-degradation
path when no model is available.

### Apple NLContextualEmbedding as the semantic tier
Measured extensively (mean pooling, corpus centering, ColBERT-style late
interaction — see [experiments/phase2-embeddings.md](experiments/phase2-embeddings.md)):
cosines cluster so tightly that unrelated queries score above correct
matches. On the dev matrix it *reduced* CLINC ranking accuracy to 63.3%
(vs 74.0% lexical-only) and drove out-of-scope abstention to 0%.
**Not recommended**; the provider ships for zero-download experimentation
but the documentation warns against production use.

### multilingual-e5-small (Core ML) as the semantic tier — CHOSEN
Dev evidence (N=25 CLINC episodes unless noted):

| Metric (dev) | Lexical | + e5 semantic |
| --- | --- | --- |
| CLINC in-scope ranking | 74.0% | **83.3%** |
| Banking77 near-duplicates (all-hard, N=10) | 67.5% | **69.0%** |
| Typo ranking | 64.7% | **68.7%** |
| Prefix (as-you-type) ranking | 56.0% | **60.7%** |
| Multilingual ranking (8 langs) | 22.0% | **47.8%** |
| Out-of-scope abstention @0.3 | high | 80–87% |
| Warm route p50 (150 actions) | 0.7 ms | ~9 ms |

Int8 quantization costs ≤0.7 pt anywhere on dev vs FP16 while halving size
(113 MB vs 224 MB) → **int8 is the recommended artifact**.

### On-device LLM (Apple Foundation Models) as the router
Not benchmarked in v0.1: hundreds of ms per decision rules it out for
as-you-type UIs, and it is gated on Apple-Intelligence hardware and
macOS 26+. Remains on the roadmap as an optional escalation tier for
ambiguous, context-heavy decisions (top-k re-ranking), where its latency
budget is acceptable.

## Key engineering choices

- **Fixed enumerated input shapes (32/64/128 tokens)** for the Core ML
  model: flexible shapes are rejected by the Neural Engine. Measured warm
  routing p50 dropped 35.8 ms → 9.1 ms and registration 10.3 s → 4.4 s.
  The attention mask is computed inside the model (`input_ids != pad`) so
  there is a single enumerated input, which Core ML requires below
  macOS 15 deployment targets.
- **Exact cosine over all candidate actions** (no vector index): at the
  target scale (up to a few hundred actions) exact scoring is faster than any ANN
  structure and adds zero dependencies. Scaling suite shows graceful
  behaviour to N=150.
- **`max + agreement bonus` fusion** instead of a weighted sum: weighted
  sums punish single-signal strength — cross-language queries have zero
  lexical support, and format abbreviations ("wav") may have weak semantic
  support. Either signal must be able to carry a match alone.
- **Per-mode confidence calibration**: fused-score distributions differ
  with and without the semantic tier; one logistic per mode keeps both
  calibrated (regenerate with `tools/dataprep/fit_calibration.py`).
- **Graceful degradation**: provider failure (missing OS assets, missing
  model file) records a reason in `SemanticTierStatus` and routing
  continues lexically. No silent failures, no crashes.

## Known limitations (v0.1)

- **Gold-absent abstention with the semantic tier is weak** (dev: 44.7% at
  the default threshold): when the right action is missing, embeddings
  confidently find the *nearest* one. Detecting "close but not it" needs
  features beyond score margin; candidate approaches (per-action score
  distributions, semantic margin features, LLM escalation) are roadmap
  items.
- Multilingual false-abstain at the default threshold is high (~30–49%
  depending on language) because cross-lingual cosines run lower than
  same-language ones; per-language calibration data would help.
- Confidence calibration was fitted on synthesized action catalogs
  (intent slugs); real product catalogs with richer descriptions should
  route *better*, but their confidence distribution may differ.
- The registration path embeds serially (~10 ms per text on this
  hardware); very large catalogs (500+ actions) pay seconds at first
  launch. Batching and persistent embedding caches are roadmap items.
