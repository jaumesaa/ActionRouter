# Roadmap

Ordered by expected value; contributions welcome (see CONTRIBUTING.md).

## v0.2 candidates

- **Better gold-absent abstention.** The known weak spot (see
  `docs/benchmarks.md`): when the right action is missing, embeddings pick
  the nearest one confidently. Explore semantic-margin features,
  per-action score distributions, and calibration features beyond
  (fused, margin).
- **Batched embedding at registration.** Serial embedding costs ~10 ms per
  text on first launch; `MLArrayBatchProvider` should cut large-catalog
  registration substantially.
- **Per-language calibration.** Cross-lingual cosines run lower than
  same-language ones; language-conditional mapping should reduce
  multilingual false-abstains.

## Later

- **Neural Engine port.** The converted encoder runs CPU/GPU today
  (enumerated-shape graph fails ANE compilation). An
  ane_transformers-style restructuring is mainly a power/battery win;
  latency is already ~9 ms.
- **Optional LLM escalation tier.** Apple Foundation Models (macOS 26+)
  re-deciding among top-k for ambiguous, context-heavy cases where a
  few-hundred-ms budget is acceptable.
- **Smaller/faster model option.** Evaluate static embeddings (model2vec
  family) as a ~30 MB, sub-ms alternative tier and measure the quality
  trade-off in the harness.
- **More platforms.** The core is pure Swift + Accelerate; Linux support
  needs an embedding provider story. Language bindings once the API
  stabilizes at 1.0.
- **Hosted DocC** documentation site.
