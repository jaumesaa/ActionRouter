# Privacy and security

## Data flow

- **Everything runs in-process, on device.** No server, no telemetry, no
  analytics, no network calls at routing time.
- **User queries** are processed in memory and never written to disk by
  the library. The embedding disk cache stores only *action metadata*
  embeddings (your app's own catalog), keyed by SHA-256 content digests —
  no raw text is persisted.
- **Network** is touched only by explicitly-invoked tooling: the optional
  `actionrouter fetch-model` command, the one-time OS asset download used
  by `NaturalLanguageEmbeddingProvider` (system-managed), and the model
  conversion scripts (developer machines only).

## Sandboxing

The library is App Sandbox-compatible: it reads the model files you point
it at and writes only to the app container's Caches directory (or a
directory you choose, or nowhere — `EmbeddingDiskCachePolicy`).

## Model provenance

The recommended model is converted from
[`intfloat/multilingual-e5-small`](https://huggingface.co/intfloat/multilingual-e5-small)
(MIT license) by `tools/convert/convert_e5.py`, which verifies numerical
parity against the reference implementation and fails the conversion if it
diverges. Convert it yourself for full supply-chain control.

## Threat notes

- Action metadata and queries are treated as untrusted *text*; they are
  never executed or interpolated into commands by this library.
- Routing decisions are suggestions with calibrated confidence; keep any
  destructive action behind your own confirmation UX regardless of
  confidence.
