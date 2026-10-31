# P1: Exact Bliss ↔ Essentia host identity proof (31 October 2026)

Status: **isolated, fail-closed module and synthetic tests only** on the
feat/essentia-exact-identity-proof branch. Not wired to active Lab DSTM,
not a settings/UI feature, not a selected General Metric, and not validated
against a real music library.

## Reason for this new proof

Lab already maps Slim::Schema::Track paths to Bliss-relative keys in
Plugin.pm::_trackToPath. This mapping serves existing mixer requests but
does not prove exact identity in both TracksV2.File and
feature_tracks.track_file. Potential concerns include root-prefix collision,
overlapping music roots, CUE suffixes, Unicode encoding and case differences.
LMS urlmd5 and artist/title are not exact feature-sidecar keys.

## Implemented read-only building blocks

BlissMixerLab/EssentiaExactIdentity.pm offers:

1. verifier_from_db_handles(bliss_dbh, feature_dbh): uses exact COLLATE BINARY
   SQL matching. Exactly one nonignored Bliss track and one-or-more feature
   rows for the same exact key must exist. Handles must be opened read-only
   by the caller. This module never writes to either database.
2. write_artifact(anchors, candidates, media_dirs, verify_key, job_id,
   directory, windows): uses only host-owned LMS track objects and media
   directories. Requires exactly one anchor, 2–50 already-admitted
   candidates and complete verification. Checks root boundary, relative traversal, duplicates, nonlocal tracks,
   case and CUE suffixes. Distinct multiple media roots are rejected outright:
   a relative TracksV2.File key alone cannot establish which physical root
   produced the row; a future host-owned root-provenance contract is required. Unicode is preserved without normalization or fuzzy joins.

Only an entirely verified batch produces a private mode-0600
essentia-exact-track-keys-v1 UTF-8 JSON file of at most 256 KiB. The
SHA-256 digest of its bytes is returned for the native SPI prepare artifact
descriptor. The native provider additionally checks fingerprints, reference
validation, vector models, dimensions and full-batch scoring. This module
does not invoke the provider. It does not change playlists or songs.

## Required next phase (not implemented)

- Capture one real host seed and the frozen eligible 2–50 song pool.
  Multiple seeds, distinct music roots and directed-edge contexts remain neutral.
- Open the correct Bliss and Essentia SQLite-v3 files read-only and ensure
  snapshot consistency, including rescan/change detection. The host owns
  paths and the music-root list, not a browser request.
- Use the proof module to generate a private hash-bound exact-key artifact
  and call the native provider through the canonical SPI v2 lifecycle.
  Delete the temporary directory on every success/error path.
- Measure anonymous coverage, neutral fallback and latency before any
  shadow UI. Do not log track paths, IDs or private song metadata.
- Validate actual Essentia model provenance, numeric feature parity,
  chosen General Metric quality, low-power performance and licences
  before enabling active weights. No change to existing Library Signals,
  Last.fm, live ranking or Better Call Bliss routes.

This is P1 implementation groundwork, **not completed P2 integration**.

## Tests

    prove -l tests/essentia_exact_identity.t

The synthetic suite covers source/schema/digest bytes, Unicode and CUE,
Windows paths, overlapping music roots, prefix/case errors, missing/duplicate
rows, duplicate IDs/keys, remote paths, traversal and pool bounds. Database
handles are deliberately mocked; a next-phase integration test must exercise
real read-only SQLite snapshots and a native provider transcript.


## P1 extension: frozen read-only sources, native SPI v2 (31 October 2026)

The new standalone EssentiaShadowProbe.pm exposes run_shadow for explicit,
trusted research execution only. It is NOT called by Plugin.pm, settings,
DSTM, existing guidance providers or Better Call Bliss. The caller must
supply shadow_opt_in=1 and trusted absolute paths to Bliss SQLite, Essentia
SQLite v3 and a separately installed native executable. No binary, audio,
ONNX weights or user music are downloaded.

Both source databases are opened using SQLITE_OPEN_READONLY, then copied
via the SQLite Online Backup API to an ephemeral private directory. This
captures WAL-aware, independently internally consistent snapshots of
each database. Both copies are reopened read-only and used for exact-key
verification. The native provider is passed ONLY the frozen Essentia copy.
The Online Backup API does not give a single *atomic cross-database*
snapshot across two unrelated SQLite databases; source-generation parity
is an outstanding additional compatibility proof. Separate copies can
represent different moments in time.

The manual probe limits each input and frozen snapshot to 256 MiB, to
prevent accidental unbounded copying and disk pressure. This is not an
approved performance strategy for large libraries or Raspberry Pi.
Oversized, nonlocal, missing or untrusted sources fail neutrally. Temporary
artifacts are destroyed on exit including errors. No raw paths or track
IDs are returned.

A true native SPI v2 JSONL transcript is constructed and verified:
describe -> prepare (job-bound SHA256 exact-key artifact, pinned model,
read-only SQLite resource, one anchor) -> score (the same complete 2-50
candidate cohort, global context) -> close. The research CI checks out
chrober/bliss-guidance-essentia at immutable revision
de72433d9c690e1aa46e973bbcca63691e959df8 and builds it from source.
The isolated subprocess has a 15-second watchdog; this does NOT represent
a production LMS response-time budget.

Only anonymous state, bounded candidate count and generic neutral reason
can escape the probe. A provider with active host policies or any nonempty
guidance signals is rejected. No route, playlist, source database or
playback mutation is performed. Real temporary SQLite fixtures test valid
feature evaluation, missing tracks, wrong model fingerprints, failed
source/native access and unchanged original database contents.

Still NOT P2 complete: native deployment/provider discovery and safe
host-side settings, live single-seed admission, multi-root provenance,
cross-database generation identity, multi-seed support, fast repeated
requests without full database copies, anonymous Lab Shadow UI, real
feature/audio parity, validated General Metric, low-power latency and
source/model distribution licence gates remain outstanding.
