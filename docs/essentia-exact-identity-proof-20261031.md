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
   candidates and complete verification. Checks root boundary, ambiguous
   roots, relative traversal, duplicates, nonlocal tracks, case and CUE
   suffixes. Unicode is preserved without normalization or fuzzy joins.

Only an entirely verified batch produces a private mode-0600
essentia-exact-track-keys-v1 UTF-8 JSON file of at most 256 KiB. The
SHA-256 digest of its bytes is returned for the native SPI prepare artifact
descriptor. The native provider additionally checks fingerprints, reference
validation, vector models, dimensions and full-batch scoring. This module
does not invoke the provider. It does not change playlists or songs.

## Required next phase (not implemented)

- Capture one real host seed and the frozen eligible 2–50 song pool.
  Multiple seeds and directed-edge contexts remain neutral.
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
