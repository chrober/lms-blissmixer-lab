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
  genre groups, DSTM count, and Last.fm behavior.
- `plugin.blissmixerlab` supplies only the learned blend, play-count influence,
  Last.fm similar-track guidance, and training-data backup path.

## Candidate reranking

BlissMixerLab never expands candidate membership beyond tracks returned by its
sidecar mixer. Upstream Last.fm artist endorsement, experimental Last.fm
similar-track evidence, and play-count influence rerank one shared candidate
pool. Last.fm recording matches prefer MusicBrainz recording IDs and fall back
to normalized artist/title identity. Track and artist request lanes run
concurrently and are bounded by a DSTM deadline; partial evidence is usable and
provider failure falls back to the remaining signals or the original Bliss
order.

The analyser and mixer may access SQLite concurrently. While upstream analysis
is running, the sidecar keeps an existing mixer available and suppresses
timestamp-driven restarts. It performs one refresh after analysis finishes so
the mixer sees the completed database without restarting for every analysed
track.

## Database lifecycle

BlissMixerLab resolves `bliss.db` in the LMS preferences directory after plugin
initialization. Before each DSTM request it queries the existing upstream
`blissmixer analyser act:status` command. It stops its mixer while analysis is
active. It also records database size and modification time and restarts
`bliss-mixer-lab` after a database change.

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
