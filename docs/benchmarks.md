# Benchmark results (v0.1)

Frozen-test results for the configurations considered in
[architecture-decision.md](architecture-decision.md). Reproduce with
`Benchmarks/README.md`; all numbers below come from one run per
configuration of `actionrouter eval Benchmarks/episodes/test` on an Apple
Silicon Mac (macOS 26), release build, after fitting calibration and
choosing thresholds **only on the dev split**.

Configurations:

- **Lexical** — no models, core library only.
- **e5-int8** — lexical + `CoreMLEmbeddingProvider` with the int8-quantized
  `multilingual-e5-small` conversion (113 MB + 21 MB tokenizer).
- **Apple NL** — lexical + `NaturalLanguageEmbeddingProvider`
  (OS-provided assets, no bundle cost).

Default abstention threshold 0.3 throughout ("answer when P(correct) ≥ 0.3").

## Headline: ranking accuracy (top-1 = gold, abstention aside)

| Suite (frozen test) | Lexical | e5-int8 | Apple NL |
| --- | --- | --- | --- |
| CLINC in-scope (N=25, hard+random distractors) | 76.5% | **81.5%** | 62.2% |
| Banking77 near-duplicates (N=10, all-hard) | 70.8% | **72.2%** | 49.8% |
| Typos (QWERTY, seeded) | 66.0% | **70.7%** | 46.7% |
| Prefixes (as-you-type, 60% of chars) | 52.7% | **55.3%** | 42.7% |
| Multilingual, 8 languages (N=20) | 23.6% | **43.2%** | 26.8% |
| Scaling mix (N=5…150) | 71.3% | **80.2%** | 64.7% |

Apple NL *hurts* versus lexical-only on every English suite — its noisy
similarity outvotes good lexical rankings in fusion. It is shipped for
experimentation only.

## End-to-end (matched AND correct, at the default threshold)

| Suite | Lexical | e5-int8 |
| --- | --- | --- |
| CLINC in-scope | 72.0% | **78.3%** |
| Banking77 | 67.8% | **72.0%** |
| Typos | 59.7% | **62.3%** |
| Prefixes | 45.7% | **51.0%** |
| Multilingual | 12.4% | **35.8%** |

## Abstention (should-not-answer episodes)

| Suite | Lexical | e5-int8 | Apple NL |
| --- | --- | --- | --- |
| Out-of-scope queries | 62.3% | **67.7%** | 0.7% |
| Gold action absent from the current set | **39.0%** | 20.3% | 0.0% |

Risk–coverage for e5-int8 (post-hoc sweep on calibrated confidence) — apps
wanting stricter behaviour raise `minimumConfidence`:

| threshold | coverage | error rate (answered) | OOS rejected |
| --- | --- | --- | --- |
| 0.30 | 82.0% | 35.0% | 44.0% |
| 0.50 | 53.9% | 22.5% | 76.2% |
| 0.70 | 31.9% | 11.8% | 91.7% |
| 0.90 | 12.2% | 4.4% | 98.7% |

## Per-language ranking (e5-int8, English action catalog)

| en | fr | es | zh | it | de | pt | ca |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 74.2% | 50.0% | 46.0% | 43.0% | 43.0% | 39.0% | 38.0% | 35.0% |

Cross-lingual routing works but trails same-language routing by ~25-35
points on these terse slug-derived catalogs; richer real-world action
descriptions close part of that gap (see limitations).

## Scaling with action-set size (e5-int8, same queries)

| N | 5 | 10 | 25 | 50 | 100 | 150 |
| --- | --- | --- | --- | --- | --- | --- |
| ranking | 88.0% | 76.0% | 73.3% | 76.7% | 76.0% | 73.3% |

Accuracy degrades gently; latency is flat (exact cosine over all
candidates).

## Latency, memory, size (this machine; Apple Silicon)

| Metric | Lexical | e5-int8 |
| --- | --- | --- |
| Warm route p50 (150 registered actions) | ~0.7 ms | ~9.3 ms |
| Warm route p95 | ~1.3 ms | ~10.4 ms |
| Cold first route | <1 ms | ~9.5 ms |
| Register 150-action catalog (750 texts) | ~4 ms | ~12 s |
| Artifact size | 0 | 113 MB model + 21 MB tokenizer |
| Peak RSS of full eval run | 27 MB | 1.4 GB* |

\* The eval process loads the Core ML model freshly for each of the 8
suites and holds all episode records; a real app loads one model once.
Single-model steady-state footprint is on the order of the model size.
Registration embeds serially (~10 ms/text); batching is a roadmap item.

## Calibration

Confidence = sigmoid over (fused score, top-2 margin), fitted per routing
mode on dev (1,450 episodes): lexical ECE 0.025 / Brier 0.166; semantic
ECE 0.033 / Brier 0.188. Fitted by `tools/dataprep/fit_calibration.py`;
coefficients live in `Confidence` (ActionRouter.swift) with provenance.
Default threshold 0.3 maximizes dev decision accuracy (correct answers +
correct abstentions): lexical optimum 0.35 → 45.9%, e5 optimum 0.25 →
57.4%; 0.3 is within 1 pt of both.

## Honest reading

- The semantic tier's biggest win is multilingual (+20 pts ranking) and
  hard catalogs (+5 pts CLINC, +9 pts scaling mix); its biggest cost is
  **gold-absent abstention** (39% → 20%): embeddings confidently pick the
  nearest action when the right one is missing. If your action set is
  complete for your domain, this rarely triggers; if users routinely ask
  for absent capabilities, raise the threshold (see risk–coverage).
- These catalogs are synthesized from dataset intent slugs and are
  deliberately harder than typical product catalogs (terse names, 25-150
  near-neighbour actions). The AnyAction-style sample catalog routes
  markedly better in informal testing.
- Numbers are single-run; episode counts (300-900 per suite) put the
  standard error around ±1-3 pts per cell.
