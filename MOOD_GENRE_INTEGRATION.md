# Mood/Genre feature identity bridge and calibration gates

**Status:** experimental integration branch only, 2026-10-19.
**Safety rule:** never merge this work into `main` without an explicit later
user decision. The original `bliss.db` and source media stay read-only.

## What this branch actually changes

`BlissFileIdentity.pm` maps Lyrion file URLs to an **exact** existing
`TracksV2.File` value through a read-only SQLite lookup. It invokes
Lab's existing `_trackToPath` conversion separately for each verified
audio directory, so CUE suffixes and decoded locale paths retain the
same format as the Bliss mixer. It rejects missing or ignored tracks,
non-file URLs, wrong-case names, duplicate keys, and ambiguous overlapping
media-root matches. A missing database or inability to open it simply
removes `database_file` from guidance metadata and preserves the previous
selection behavior.

The adapter optionally accepts `database_file_resolver` for both
`profile_from_provider` and `lastfm_evidence_from_provider`. The former
transmits verified keys in the already bounded candidate batch; the latter
transmits them in **both seed anchors and candidates**. Lab's runtime only
supplies that resolver to existing provider flows. Their native policies,
timing, signal weighting and candidate admission are otherwise untouched.
No separate Mood/Genre provider is yet installed or enabled in Lab.
In particular, the existing Library Signals request has no seed anchors:
a feature-similarity plugin cannot simply replace Library Signals.

## Three equal alternatives — NOT decided

- **Bliss-first**: acoustically admitted Bliss candidates receive
  additional Mood and Genre guidance. Candidate recall remains bounded by
  the Bliss pool.
- **Mood-/Genre-first**: features retrieve candidates, and Bliss scores
  transitions afterwards. Requires a separate host-controlled candidate
  source/index, not only the current SPI v2 reranking callback.
- **Hybrid**: combine and deduplicate candidates from both sources, then
  rank with calibrated evidence and apply shared Lyrion hard constraints.

Bliss-first was the **first integration smoke test** only because it
reuses the existing host's bounded shortlist. It has not been selected
as the final musical strategy. The feature bridge is strategy-neutral:
a future feature candidate-source contract can reuse the exact key join
and read-only sidecar access without modifying source audio or `bliss.db`.

## Signal calibration — MUST remain a separate gate

The prototype provider currently calculates, independently for Mood
(56-dimensional Sigmoid) and Genre (87-dimensional Sigmoid), approximately
`score = 1 - 2 * RMS(seed_vector - candidate_vector)`, clamped to [-1,1].
That number is a **raw vector proximity heuristic**. It is **not** a
probability and not a validated or cross-model-comparable similarity.
A score of 0.90 between unrelated songs can occur when many output
classes are near zero for both tracks. Consequently, do not directly
equate a provider's raw 0.90 with 90% genre/mood similarity; do not
mix raw genre and mood scores or add them directly to Bliss distances.

Before enabling feature-based reranking or hybrid candidate admission:

1. Verify scoring provenance/model fingerprint and the ordered model
   class labels, using representative real audio and reference
   predictions. Unvalidated head scores require a conspicuous Lab-only
   experimental opt-in and must not become production defaults.
2. Build a frozen comparison set of positive and difficult negative
   track pairs, including strong genre contrast, similar production
   with different genre, subtle mood contrast, multi-genre, and CUE.
   Capture empirical per-head score distributions and rank-order
   discrimination; compare alternatives such as centred cosine,
   weighted top-class overlap, standardized distances, and
   head-specific nearest neighbours.
3. Calibrate or robustly normalize **within each head** on a frozen
   candidate pool (e.g. quantiles/ranks), with explicit missingness
   and uncertainty. Prevent artificially high confidence when there
   is only one seed or uniformly high scores; do not fit on the
   evaluation set.
4. Run blinded Bliss-only vs Bliss-first vs Mood-/Genre-first vs Hybrid
   listening comparisons on the same eligible tracks, seed and hard
   filters. Track candidate recall, musical transitions, drift,
   diversity, repeated artists, fallback and Pi latency.
5. Keep **genre influence=0 and mood influence=0 by default** until the
   evidence supports a calibrated independent choice. Disabling both,
   missing file keys, provider failure or corrupt sidecar must reproduce
   existing Bliss behavior.

These are gating requirements, **not** features claimed implemented by
this branch. PR #13 in `chrober/bliss-mood-poc` remains an experimental
native scorer; it is neither a Lyrion plugin nor a calibrated algorithm.
The first Lab integration slice is the verified file-key bridge only.

## Verification

Regression tests:
- `tests/bliss_file_identity.t`: read-only SQLite, exact/case-sensitive
  and Unicode keys, CUE, media-root boundaries/ambiguity, duplicates,
  ignored tracks, non-file URLs, missing database.
- `tests/guidance_provider_adapter.t`: opt-in resolver produces exact
  candidate and anchor `database_file`; absent/failing resolver
  preserves neutral legacy results.

CI: `python tests/validate_repository.py`,
`python -m unittest discover -s tests -p "test_*.py"`, and
`prove -l tests` in the existing repository workflow.
