# Phase 2 experiment log — embedding provider quality

Date: 2026-07-10. Machine: Apple Silicon, macOS 26.

Mini-benchmark: 8 file-tool actions (name + description + keywords),
12 queries (Catalan / Spanish / English, incl. 2 out-of-scope). Full scripts
retained in session scratchpad; dataset embedded in the scripts. This is a
smoke test that motivated architecture choices — the real, reproducible
benchmark harness lands in Phase 3/4.

## NLContextualEmbedding (Apple, mean-pooled, script .latin)

| Strategy | Gold top-1 | Notes |
| --- | --- | --- |
| raw mean pooling | 3/8 core queries, 5/10 extended | cosines cluster 0.65–0.80 for *everything*; top1−median spread 0.01–0.04 |
| corpus-centered ("all-but-the-top") | worse rankings | separation improves (0.05–0.24) but hub actions dominate |
| late interaction (per-token max-cos, ColBERT-style) | 5/10 | out-of-scope "order a pizza" scored 0.795 — *higher than several correct matches* |

Conclusion: NLContextualEmbedding is not reliable for fine-grained action
discrimination in any pooling variant we tried, and its absolute scores are
unusable for abstention. It remains available as a zero-bundle-cost
provider (`NaturalLanguageEmbeddingProvider`), useful as a weak
cross-language signal on top of the lexical tier.

## multilingual-e5-small (PyTorch reference, then Core ML)

Same mini-benchmark: **9/10 gold top-1** (miss: highly colloquial clipped
Catalan "retallar la canco"). In-scope cosines 0.83–0.90; out-of-scope
0.73–0.77 → a raw-cosine abstention threshold is viable (provisional
mapping: floor 0.75, ceiling 0.90 — `SemanticConfiguration.e5`).

Core ML conversion (`tools/convert/convert_e5.py`):

| Artifact | Size |
| --- | --- |
| MultilingualE5Small.mlpackage (FP16) | 224 MB |
| MultilingualE5Small-Int8.mlpackage | 113 MB |
| tokenizer files | 21 MB |

- Parity Core ML vs PyTorch: worst cosine **0.999993** over 5 multilingual
  probes (CPU-only compute units).
- Swift tokenizer (swift-transformers `AutoTokenizer`) reproduces the
  Hugging Face reference token IDs exactly on 8 fixtures incl. Chinese,
  emoji and German (see `Tests/ActionRouterCoreMLTests`).
- Warm end-to-end routing latency via CLI on this machine: ~27–30 ms per
  query (flexible-shape model falls back off the Neural Engine — the
  "E5RT … Data-dependent shapes" load-time message; enumerated fixed shapes
  are a Phase 4 experiment).
- Known conversion pitfalls (pinned in `tools/convert/requirements.txt`):
  transformers 5.x traces `new_ones` (unsupported by coremltools 9);
  Python 3.14 lacks coremltools' BlobWriter native extension — use 3.12.

## Decision impact

- The semantic tier's default quality path is a converted E5-family Core ML
  model; Apple NL embeddings are the no-download fallback, weighted weakly.
- Both ship behind the same `EmbeddingProvider` protocol; the router
  degrades to lexical-only when a provider fails (`SemanticTierStatus`).
- Phase 4 must benchmark: e5 FP16 vs Int8 quality, fixed vs flexible
  shapes (ANE), example-embedding noise (per-example max raised hubness on
  the weak provider), and fit real confidence calibration.
