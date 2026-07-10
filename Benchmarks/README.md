# ActionRouter benchmark harness

Reproducible evaluation of *dynamic* intent routing — not fixed-label
classification. Every episode is one routing decision: a query, the subset
of actions available at that moment, and the expected outcome (an action id
or an explicit abstention).

## Running

```sh
# Lexical tier only (no models):
swift run -c release actionrouter eval Benchmarks/episodes/test

# With the Apple NLContextualEmbedding provider:
swift run -c release actionrouter eval Benchmarks/episodes/test --semantic

# With the converted multilingual-e5-small Core ML model:
swift run -c release actionrouter eval Benchmarks/episodes/test \
    --e5-dir tools/convert/build

# Machine-readable report:
swift run -c release actionrouter eval Benchmarks/episodes/test \
    --json-out report.json
```

## What is measured

- **End-to-end accuracy** — router returned `.matched` with the gold action.
- **Ranking accuracy / MRR** — gold is top-1 / mean reciprocal rank,
  independent of abstention (separates ranking quality from calibration).
- **False-abstain rate** — in-scope queries the router wrongly declined.
- **Correct abstention** — out-of-scope queries (`oos` tag) and queries
  whose gold action is not currently available (`absent` tag).
- **Risk–coverage sweep** — post-hoc confidence-threshold sweep showing the
  coverage/error trade-off and OOS rejection at each threshold.
- **Latency** — action registration, cold first route, warm p50/p95.
- **Peak RSS** and grouping by language / action-set size / perturbation tag.

## Suites

| Suite | Source | Stresses |
| --- | --- | --- |
| clinc-inscope | CLINC-150 | 150 intents, mixed hard+random distractors, N=25 |
| clinc-oos | CLINC-150 | explicit out-of-scope → must abstain |
| clinc-absent | CLINC-150 | in-scope query, gold action *not available* → must abstain |
| clinc-typo | CLINC-150 | seeded QWERTY typos (swap/drop/neighbour) |
| clinc-prefix | CLINC-150 | truncated as-you-type queries (60% of chars) |
| clinc-scaling | CLINC-150 | same queries at N = 5/10/25/50/100/150 |
| banking77-similar | Banking77 | N=10 where *all* distractors are the nearest intents |
| massive-multilingual | MASSIVE 1.1 | en/es/ca/fr/de/it/pt/zh queries vs an English action catalog |

`dev/` (1,450 episodes) is for tuning and calibration; `test/` (3,900
episodes) is frozen — do not tune against it. Queries come from each
dataset's validation/test splits respectively; action usage examples come
only from train splits, so no evaluation query appears in action metadata.

## Regenerating

Episodes are committed for exact reproducibility. To regenerate from raw
data (same seed → byte-identical output):

```sh
cd tools/dataprep
curl -sL -o cache/massive-1.1.tar.gz https://amazon-massive-nlu-dataset.s3.amazonaws.com/amazon-massive-dataset-1.1.tar.gz
tar xzf cache/massive-1.1.tar.gz -C cache
curl -sL -o cache/clinc-data_full.json https://raw.githubusercontent.com/clinc/oos-eval/master/data/data_full.json
curl -sL -o cache/banking77-train.csv https://raw.githubusercontent.com/PolyAI-LDN/task-specific-datasets/master/banking_data/train.csv
curl -sL -o cache/banking77-test.csv https://raw.githubusercontent.com/PolyAI-LDN/task-specific-datasets/master/banking_data/test.csv
python3 build_episodes.py --seed 42
```

## Dataset licenses and attribution

Episode files embed utterances derived from:

- **CLINC-150** ([clinc/oos-eval](https://github.com/clinc/oos-eval)),
  CC-BY-3.0. Larson et al., *An Evaluation Dataset for Intent Classification
  and Out-of-Scope Prediction*, EMNLP 2019.
- **Banking77** ([PolyAI-LDN/task-specific-datasets](https://github.com/PolyAI-LDN/task-specific-datasets)),
  CC-BY-4.0. Casanueva et al., *Efficient Intent Detection with Dual
  Sentence Encoders*, 2020.
- **MASSIVE 1.1** ([amazon-science](https://github.com/alexa/massive)),
  CC-BY-4.0. FitzGerald et al., *MASSIVE: A 1M-Example Multilingual Natural
  Language Understanding Dataset*, ACL 2023.

Action names/descriptions are generated from intent slugs; they are not
part of the source datasets.

## Known limitations

- Action catalogs are synthesized from intent slugs, so action names are
  terser than typical real product actions (this makes routing *harder*
  than the AnyAction-style catalogs in `Examples/`).
- The risk–coverage sweep re-thresholds the top candidate's confidence
  post hoc; the router's own ambiguity policy is not swept.
- Hard distractors are selected by token-profile similarity (model-free);
  they are adversarial for the lexical tier and only approximately
  adversarial for embedding providers.
