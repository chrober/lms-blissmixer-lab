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

- `plugin.blissmixer` supplies filters, repeat limits, weights, seed strategy,
  genre groups, DSTM count, Last.fm artist probability, and play-count
  influence.
- `plugin.blissmixerlab` supplies only the learned blend, Last.fm
  similar-track guidance, Last.fm artist reranking mode and bounded influence,
  last-played and library-age influence plus their saturation horizons, and
  training-data backup path.

## Candidate reranking

BlissMixerLab requests candidates from its sidecar mixer using the Static
Weights, EIF, or Adaptive Weightings strategy configured in Bliss Mixer. It
delegates Last.fm artist and play-count reranking to Bliss Mixer's shared
candidate selector, adding its Last.fm recording-similarity factor and optional
local listening/library factors to the same selection pass. Last-played and
library-age values are read in one bounded lookup against Lyrion's
`persistentdb.tracks_persistent` table for the Bliss-derived DSTM pool, not by
scanning the library. They use the same signed `-100` through `100` preference
semantics as upstream play-count influence. Learned-matrix weighting applies
only to Adaptive Weightings. Last.fm recording matches prefer MusicBrainz
recording IDs and fall
back to normalized artist/title identity. Track and artist request lanes run
concurrently and are bounded by a DSTM deadline; partial evidence is usable and
provider failure falls back to the remaining signals or the original Bliss
order.

### Last.fm artist reranking

BlissMixerLab offers two explicitly selected modes:

| Mode | Meaning | Setting used |
| --- | --- | --- |
| **Bounded artist influence** (default) | Every artist-endorsed candidate receives a bounded multiplier comparable to the other reranking factors. | Lab artist influence, `0..100`; `25` is about `1.8x`, `50` about `3.2x`, and `100` up to `10x`. |
| **Target endorsed share** | Delegates to the upstream BlissMixer percentage semantics, requesting a best-effort share of selected candidates endorsed by Last.fm artist evidence. | Upstream BlissMixer Last.fm artist probability. |

The default mode prevents a single Last.fm artist match from overwhelming
play-count, last-played, library-age, and Bliss similarity factors. In both
modes, Last.fm only reranks the Bliss-derived pool; it cannot add a candidate
outside that pool or bypass a hard constraint.

At information level, the plugin reports the active mode, number of artist
matches, configured influence or target, and the calculated boost range. Debug
logging additionally reports `Last.fm-artist-mode` for every selected
candidate and shows the artist multiplier separately from the other factors.

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
- missing metadata is neutral; and
- a `lastPlayed` value of zero (“never played”) is treated as maximally
  overdue.

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

Local library signals deliberately do not rely on Alternative Play Count (APC).
APC can later be represented by a separate provider with its own semantics;
this Lab feature uses only Lyrion's built-in persistent metadata.

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
