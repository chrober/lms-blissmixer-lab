# Provider-neutral seed context for Guidance SPI v2

**Status: research-only stacked Draft PR #6 (31 October 2026)**,
branch `feat/generic-guidance-seed-context` based on the separate
`test/spi-v2-anchor-forwarding-vendor` Draft PR #5. Neither the
Lab `main` branch nor the production Lyrion instance is touched.

## Existing implementation reused rather than reinvented

The Last.fm route already supplies real `@seedsToUse` tracks to
`GuidanceProviderAdapter::lastfm_evidence_from_provider`, which
assigns stable host route IDs `seed-1`, `seed-2`, ... to
`prepare.anchors` and `score.context.context_track_ids`, while
preserving `candidate_id` as each source's original Lyrion URL.
Those fields are distinct by the normative Guidance SPI v2 contract.

The identical logic is now extracted into the shared adapter function
`build_seed_context($seeds)`. Both the Last.fm path and the generic
`profile_from_provider` call it. The Lab DSTM caller passes its
existing frozen `@seedsToUse` to the generic adapter as
`operations->{seeds}`. The generic helper preserves all supported
seed metadata including `lms_urlmd5`, MusicBrainz IDs and artist fields.
Invalid seeds do not get an anchor, and the original numeric positions
are retained exactly as in Last.fm's previous implementation.

## Compatibility guarantees

- **Last.fm:** no changed anchor numbering, candidate membership,
  source identity, scores or log format; existing regression tests
  still exercise direct Last.fm route context and MBIDs.
- **Library Signals:** the native provider ignores optional
  `prepare.anchors` and does not use `score.context_track_ids`;
  introducing them for the actual DSTM call does not affect
  its full candidate cohort, playcount, last-played, library age,
  selection input or formatter output. A direct adapter call with
  no `seeds` still retains the previous anchor-free request shape.
- **Research-only Essentia:** the same helper carries original
  Lyrion seed identity, metadata and the bounded admitted candidate
  batch to the existing SPI host; an explicit `signals=[]` native
  fixture remains neutral and cannot influence DSTM ranking.
  This test uses a controlled mock native result: it does **not**
  activate the Essentia plugin or claim that model geometry is
  validated.
- **All providers:** existing candidate eligibility and ordering
  remain host-owned; no new seed optimization, source-root guessing,
  automatic Essentia analysis, API version or provider conditional
  was introduced.

## Remaining provider-owned identity issue (do not conceal)

The current experimental `lms-guidance-essentia` exact-key artifact
stores its anchor row using the **file URL** as `track_id`, while
the actual generic host uses its separate **route token**
`seed-1` as `anchor_id`. The native Essentia implementation
requires that `anchor_id` resolve to the exact-key artifact row;
it will reject an unbound alias. A verified, read-only
provider-owned binding from `seed-1` to the corresponding
`file://` source and root-relative `track_file` remains to be
implemented and tested before an **actual** Lab-native Essentia
end-to-end test can succeed. Do not forge validation flags or
silently choose one seed from a multi-seed request; the current
native Essentia scorer requires exactly one source context.

The real Lab native guidance path through
`_guidanceHostPayload` and `bliss-mixer` already forwards
`anchors`; the canonical shared Perl runtime has separately
been corrected in [host Draft PR #1]
(https://github.com/chrober/lms-bliss-guidance-host/pull/1).

## Tests and review

- `tests/guidance_provider_adapter.t`: existing Last.fm and
  Library Signals contracts and exact native profile/formatter data.
- `tests/generic_guidance_seed_context.t`: cross-provider helper,
  source identity mapping and ordering, no-seed compatibility,
  unchanged Library Signals scores and neutral/fail-closed
  Essentia-shaped responses.
- `tests/guidance_runtime_anchors.t`: generic Perl JSONL transport
  regression on the parent test branch.
- `tests/plugin_contract.t`: independent Lab integration and
  historical formatter contracts.

Review CI in [stacked Draft PR #6]
(https://github.com/chrober/lms-blissmixer-lab/pull/6).

**No merge, release, deployment, restart or player operations.**
