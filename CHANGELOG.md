# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com); versioning is semantic.

## [0.1.0] - 2026-07-10

First public release candidate.

### Added
- Core routing engine (`ActionRouter` actor): dynamic action registration,
  lexical tier (Unicode-folded exact/prefix, typo-tolerant fuzzy tokens,
  trigram phrase similarity, field-weighted BM25), optional semantic tier
  behind the `EmbeddingProvider` protocol, `max + agreement bonus` fusion.
- Calibrated confidence (per-mode logistic fitted on dev benchmark suites)
  with explicit abstention (`insufficientConfidence`, `ambiguous`,
  `emptyQuery`, `noActionsRegistered`).
- `RoutingContext`: hints (soft boost) and `allowedActionIDs` (per-call
  hard filter without re-registering).
- `ActionRouterCoreML`: provider for converted E5-family Core ML models,
  exact Hugging Face tokenizer parity, enumerated-shape models.
- `tools/convert/convert_e5.py`: reproducible multilingual-e5-small →
  Core ML conversion (FP16/int8) with a numerical parity gate.
- Persistent embedding disk cache (content-addressed; user queries are
  never persisted) — `EmbeddingDiskCachePolicy`.
- `NaturalLanguageEmbeddingProvider` (Apple NLContextualEmbedding),
  shipped for experimentation with a measured warning against production
  use.
- Live reconfiguration: `updateConfiguration(_:)`.
- Benchmark harness: 5,350 committed routing episodes (CLINC-150,
  Banking77, MASSIVE 1.1; multilingual, OOS, gold-absent, typo, prefix,
  scaling) + `actionrouter eval` metrics/reports.
- `actionrouter` CLI (`route`, `eval`, `fetch-model`) and
  `RouterPlayground`, a live decision-visualization macOS app.
- Documentation: architecture decision record, benchmark results,
  integration guide, privacy notes, roadmap.
