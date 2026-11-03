# Architecture

BlissMixerLab is a sidecar, not a runtime patch. It uses public LMS facilities
and shared on-disk analysis data but does not replace upstream Perl packages or
registrations.

## Ownership boundary

| Concern | Bliss Mixer | BlissMixerLab |
| --- | --- | --- |
| Library analysis and `bliss.db` writes | Owner | Read-only consumer |
| Stable mix preferences | Owner | Reads on every request |
| Experimental preferences | None | Owner |
| Mixer process | `bliss-mixer` | `bliss-mixer-lab` |
| Learning process | None | `bliss-learner` |
| DSTM provider | `Bliss` | `Bliss (Lab)` |
| Survey, triplets, learned matrix | None | Owner |

The two preference namespaces are deliberately separate:

- `plugin.blissmixer` supplies the base strategy, filters, repeat limits,
  weights, seed strategy, genre groups, and DSTM count. Its play-count
  preference remains relevant to the legacy fallback when Library Signals is
  not active.
- `plugin.blissmixerlab` owns Lab-specific settings, including the learned
  blend, provider enablement and overrides, and the training-data backup path.
- Discoverable guidance providers own their default policies. Lab may override
  supported values without changing the provider defaults.

## Candidate reranking

BlissMixerLab requests candidates from its sidecar mixer using the Static
Weights, EIF, or Adaptive Weightings strategy configured in Bliss Mixer. It
uses discoverable, explicitly enabled guidance providers to influence selection
within that Bliss-derived pool. The native Library Signals provider reads
trusted Lyrion or optional Alternative Play Count history for the candidates;
the Last.fm provider can use LastMix or its direct API Key path. If Library
Signals is not enabled, the legacy local selection path remains available.
See [provider host integration](GUIDANCE_PROVIDER_HOST_INTEGRATION.md) for the
request paths and fallback behavior. Learned-matrix weighting applies
only to Adaptive Weightings. Last.fm recording matches prefer MusicBrainz
recording IDs and fall
back to normalized artist/title identity. Track and artist request lanes run
concurrently and are bounded by a DSTM deadline; partial evidence is usable and
provider failure falls back to the remaining signals or the original Bliss
order.

### Last.fm artist reranking

The Last.fm provider offers two explicitly selected modes, inherited or
overridden by the host:

| Mode | Meaning | Setting used |
| --- | --- | --- |
| **Per-candidate boost** | Each artist-endorsed candidate receives a bounded multiplier that competes with the other reranking factors. | Provider artist influence, `0..100`; `25` is about `1.8x`, `50` about `3.2x`, and `100` up to `10x`. |
| **Target share** | Requests a best-effort share of selected candidates endorsed by Last.fm artist evidence; the resulting boost can dominate other factors. | Provider artist target share. |

The per-candidate mode bounds the contribution of an artist match. In both
modes, Last.fm only reranks the Bliss-derived pool; it cannot add a candidate
outside that pool or bypass a hard constraint.

At information level, the plugin reports the active mode, number of artist
matches, and configured influence or target. Debug logging additionally shows
the selected candidates' artist multipliers alongside the other factors.

### Saturating last-played and library-age signals

The date signals are deliberately based on elapsed time rather than the rank of
the current candidate pool. For a timestamp `t`, a run-wide reference time
`now`, and a configured horizon `H` days, the raw signal is:

```text
remaining = exp(-(now - t) / (H days))
signal = 2 * remaining - 1
```

The existing signed influence then converts the signal into a bounded
multiplier:

```text
weight = 10 ^ (influence / 100 * signal)
```

Consequences:

- positive last-played influence favors recent plays;
- negative last-played influence favors tracks played longer ago;
- positive library-age influence favors newly added tracks;
- negative library-age influence favors older additions;
- five- and six-year-old tracks receive nearly the same age signal when the
  horizon is much shorter than either age;
- missing metadata is neutral. Provider-specific source handling determines
  which timestamps are available.

The settings are:

| Signal | Influence range | Saturation horizon | Default |
| --- | ---: | ---: | ---: |
| Last played | `-100..100` | `30..1825` days | `180` days |
| Library age | `-100..100` | `30..3650` days | `365` days |

The horizon is an e-folding saturation constant: after one horizon, the raw
exponential has fallen to about `36.8%`; dates several horizons apart are close
to the same saturated value. Each run captures one `as_of` timestamp so all
candidates are evaluated consistently.

Information logging reports the active influence, horizon, and number of known
timestamps. Debug logging reports each selected candidate's date-derived signal
and multiplier, followed by the combined reranking weight and the dominant
boost.

Library Signals uses Lyrion's built-in persistent metadata by default. When
Alternative Play Count (APC) is installed and explicitly selected, the same
provider can source play count and last played from APC while retaining
Lyrion's first-seen timestamp for library age. APC-only skip history, DPSV, and
other richer listening signals remain separate future guidance semantics.

The analyser and mixer may access SQLite concurrently. While upstream analysis
is running, the sidecar keeps an existing mixer available and suppresses
timestamp-driven restarts. It performs one refresh after analysis finishes so
the mixer sees the completed database without restarting for every analysed
track.

## Database lifecycle

BlissMixerLab resolves `bliss.db` in the LMS preferences directory after plugin
initialization. Before each DSTM request it queries the existing upstream
`blissmixer analyser act:status` command. It keeps an existing mixer available
while analysis is active, defers timestamp-driven restarts, and refreshes
`bliss-mixer-lab` once the analysis has completed.

No Lab code starts an analyser or opens the database for writes.

## Binary isolation

The experimental mixer has a unique installed filename. It binds to
`127.0.0.1` on an automatically selected Lab-owned port, avoiding the
experimental binary's upstream-specific dynamic-port callback. The learner has
the canonical `bliss-learner` name because upstream Bliss Mixer has no learner
binary with which it could conflict. It is monitored as a local child process
and does not send notifications to the upstream CLI endpoint.

Learning writes to a temporary matrix. The active matrix is replaced only when
the learner produces a new result, preserving the previous model after a failed
experiment.

Native executables are released independently by `chrober/bliss-mixer` and
`chrober/bliss-learner`. BlissMixerLab pins both release tags and commits, checks
their published SHA-256 files, and renames the verified assets only while
assembling plugin packages. Workflow artifacts are never used as durable release
inputs.

## Feature graduation

When an experiment is accepted upstream:

1. Release an Lab version that recognizes the upstream version containing it.
2. Migrate any Lab preference or data that users should retain.
3. Remove the graduated setting and implementation from Lab.
4. Stop registering `Bliss (Lab)` when it no longer provides distinct behavior.

## Upstream DSTM drift

`compat/dstm-drift.json` records the upstream commit against which the adapted
DSTM routines were last reviewed. It also separates direct mirrors from
intentional adaptations. `.github/workflows/dstm-drift.yml` checks both parts:

- Direct mirrors are compared between current upstream and BlissMixerLab after
  removing comments, layout, and the expected plugin-identity differences.
- Intentional adaptations are compared between current upstream and the recorded
  reviewed upstream commit, so a new upstream change cannot be hidden by the
  sidecar's existing learned-matrix differences.

The workflow reports changed routines rather than a noisy whole-file diff. Its
scheduled run maintains one review issue until all significant drift has been
resolved and the reviewed commit has deliberately been advanced.
