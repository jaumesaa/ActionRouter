# Contributing to ActionRouter

Thanks for helping! A few ground rules keep the project trustworthy.

## Development

```sh
swift build
swift test                       # deterministic suite (no models needed)
ACTIONROUTER_E5_DIR=tools/convert/build swift test   # + model-gated tests
swift run RouterPlayground       # live diagnosis
```

Model artifacts are not in the repo; produce them with
`tools/convert/convert_e5.py` (see `tools/convert/requirements.txt`).

## Principles

- **Evidence over intuition.** Anything that can change routing quality
  (scoring, fusion, calibration, providers, default thresholds) must come
  with `actionrouter eval` results on the dev suites, and must not be
  tuned against `Benchmarks/episodes/test` — that split is frozen.
- **Never hand-edit fitted constants.** Calibration coefficients are
  regenerated with `tools/dataprep/fit_calibration.py`; include the fitting
  output in the PR.
- **The core stays dependency-free.** New dependencies belong in separate
  library targets (like `ActionRouterCoreML`) and need a justification of
  their cost.
- **Privacy invariants** (see `docs/privacy.md`): no network at routing
  time, no persistence of user queries. PRs violating these are rejected.
- **No silent failure.** Degradations must be observable
  (`SemanticTierStatus`, thrown errors, or logs).

## Style

- Swift 6 language mode, `Sendable`-clean; actors for shared mutable state.
- Public API gets doc comments; user-facing behaviour gets tests.
- Commit messages explain *why*; benchmark-affecting commits quote numbers.

## Releases

See `docs/releasing.md`. Versioning is semantic: breaking API → major
(pre-1.0: minor), features → minor, fixes → patch.
