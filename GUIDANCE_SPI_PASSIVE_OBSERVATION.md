# Passive provider observation through the existing Guidance SPI

Status: experimental, **not wired to DSTM or playback**, on a Draft PR.
The host code does not import, identify, configure or interpret any
particular third-party provider. Providers own their own source data,
trusted resources, keys, schema, algorithms and supported host policies.

## Purpose

The existing native guidance path accepts `provider` configuration,
`artifacts`, `resources`, one or more `anchors`, `context` and the
already-admitted candidate pool. The experimental
`GuidanceProviderAdapter::observe_via_spi()` method exercises that same
host path with a passive result, without selecting or reranking songs.
No second JSONL processor, direct subprocess or private provider SQL
reader is introduced.

## Safety contract

- Manual opt-in must be the literal scalar `1`; default is neutral.
- A valid enabled provider policy and both standard host callbacks
  (`native_config`, `score_batch`) are required.
- Exactly one seed and 2–50 already-admitted candidates. Every track
  must have distinct, complete LMS URL and URL hash identities;
  incomplete/ambiguous batches fail before provider invocation.
- The existing generic `eligible-candidate-identities-v1` artifact is
  created for the exact seed and candidate pool. The host keeps the
  same job ID in the trusted provider configuration and SPI request.
- The same SPI request carries the unchanged seed as an `anchor`
  and in `context_track_ids`; candidates retain their original order.
- The standard SPI host callback owns the native program launch,
  protocol validation, trusted configuration and deadline. This helper
  does **not** start or communicate directly with a subprocess.
- A passive observation is accepted only for a valid SPI response
  containing exactly **zero active guidance signals**. Provider errors,
  timeouts, malformed output and attempts to return active signals
  fail neutral. No private diagnostics, track names or raw paths are
  returned to the caller.
- Nothing in the current DSTM path invokes this method. No queue,
  selection, settings, route, playlist or playback behavior is changed.

## Missing integration gates

- This currently uses a callback-driven synthetic SPI test. A real
  native provider must separately prove that it can consume a trusted
  host/provider-generated identity mapping and its own resources.
- The generic host artifact contains LMS URL and URL hash; these are
  not necessarily a physical file or feature database key. Any
  provider requiring a stronger identity must supply its own
  independent attestation; this host must never guess that key.
- The extension remains non-live. Attach to a running server only
  after the provider, source-provenance, performance and independent
  safety gates are complete.

## Verification

`prove -l tests/guidance_spi_passive_observation.t`

This deliberately provider-neutral test covers disabled operation,
complete seed/candidate ordering, generic artifact, matching job IDs,
whole-query fallback, provider failure isolation and rejection of
nonempty active signals.
