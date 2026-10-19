# Generic SPI guidance routing (Draft PR #2)

**Branch:** `feat/mood-genre-feature-identities`. **Never merge into
`main` without new, explicit user instruction.**

## Why this replaces the earlier Mood/Genre-specific changes

The initial PR #2 added a separate `BlissFileIdentity.pm`, additional
`bliss.db` reads and a special Mood/Genre file resolver to the existing
provider paths. All those edits, their tests and the old
`MOOD_GENRE_INTEGRATION.md` have been **reverted/deleted**. The shared
SPI v2 already supports `database_file` in anchors and candidates, and
Lab can derive relative Bliss file keys from its original `_trackToPath`
logic without another database reader.

## Generic host execution

Three layers now have separate responsibilities:

1. **Provider discovery, descriptor controls, enablement, native setup, and
   bounded host endpoint** stay with the existing
   `BlissGuidance::Discovery`/`Policy`/`SettingsModel` shared host and
   `_scoreGuidanceThroughMixer`.
2. **SPI transport and local track identity** are provided by
   `GuidanceProviderAdapter::invoke_provider` and
   `candidate_identity_for_track`. This invocation method has no
   hardcoded provider ID or channel. The existing Library Signals and
   Last.fm wrappers now call this same method; their exact request
   shapes, response mappings, selection algorithms and INFO/DEBUG log
   formatters remain unchanged.
3. **Additional providers** use `GenericGuidance.pm`: any discoverable,
   enabled descriptor with integer `guidance_channel` controls and bounded
   influence can submit a bounded SPI v2 candidate batch through the same
   transport. Valid `[-1,1]` scores may generate independent
   multiplicative candidate weights
   `10 ** (influence / 100 * score)`. Unsupported target-share modes
   are not silently approximated as bounded influence. Scores naming
   candidates outside the frozen Bliss batch, undefined/invalid scores,
   missing channels, uniform scores and provider failures are neutral.
   Independent channels/provider weights multiply only after the host's
   existing eligibility and repeat checks. Native provider options
   and trusted resources must come from the registered provider;
   playlist requests cannot pass executable or SQLite paths.

The additional-provider host path passes anchor and candidate IDs plus
their optional root-scoped `database_file` keys using the existing
`_trackToPath` formatting. It refuses ambiguous media roots and paths
outside a configured audio root. It does **not** validate that a feature
sidecar contains that key; missing vectors must be handled neutrally
by the read-only feature provider.

## Compatibility and rollout limits

The known provider IDs `lastfm` and `library-signals` remain on their
specialized *policy adapters*, because Last.fm target share, artist/track
match semantics, Library Signals observations, and their existing log
fields must remain byte-for-byte compatible. **Their SPI invocation
layer is now shared**, and arbitrary *new* providers no longer require
editing those adapters. The historical providers are excluded from the
generic weighting pass so they are never applied twice. The next
refactoring step, if desired, is to migrate each old policy to a
descriptor-driven policy adapter, but only after frozen selection and
logging parity tests prove equivalence.

When no third-party provider is configured/enabled, Lab does not make
an additional discovery call or start extra guidance processes, and
every old selection/logging path remains unchanged. Generic providers
must be deliberately enabled by the user; adding a plugin alone is
not permission to alter a playlist.

**Not yet demonstrated:** full end-to-end ABI/runtime operation of
an arbitrary provider with the released native `bliss-mixer-lab` host,
or calibrated musical quality. Source-level and mocked-SPI regression
tests are not substitutes for live Lyrion tests.

## Calibration and product strategy

Bliss-first, Mood-/Genre-first, and Hybrid remain equally valid
**undecided** strategies. The currently implemented SPI scoring path
reranks an already Bliss-admitted pool; feature-first and Hybrid
candidate admission would require a new generic host candidate-source
contract, not a Mood-specific branch in Lab.

The prototype Mood/Genre RMS-proximity scores are **not calibrated
similarity probabilities**; a 0.9 between different styles is not 90%
musical similarity. The independent 56D Mood and 87D Genre heads must
be validated against actual recordings, their distributions measured,
and their scores calibrated/normalized per channel before nonzero
influence is recommended. Unvalidated model predictions must not
silently become default production guidance.

## Test gates

CI runs the existing `prove -l tests`, Python validation and DSTM
drift tests. `tests/generic_guidance.t` introduces a *third, deliberately
unfamiliar provider name and channels* and checks descriptor-based
scoring, frozen anchors/candidates, bounded weights, missing data,
zero-influence, uniform signals and neutral failures. The pre-existing
`guidance_provider_adapter.t`, `plugin_contract.t` and
`test_dstm_drift.py` continue to verify the established providers
and their documented selection/logging contracts.

Until those tests and a live trial are reviewed, **PR #2 stays Draft
and `main` remains unchanged**.
