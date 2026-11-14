# Bliss Mixer Lab improvement backlog

This is a re-orderable list of proposed work. Move complete rows to change
priority; sizes are rough engineering estimates, not time commitments.

| Improvement | Intended outcome | Size | Status | Details |
| --- | --- | ---: | --- | --- |
| Continue DSTM from non-library tracks | Let Bliss (Lab) continue from eligible Bandcamp, YouTube, or other remote tracks when a reliable seed can be established. | XL | Research and design needed | [Remote and streaming seeds](#remote-and-streaming-seeds) |
| Carry player libraries with transferred queues | Explore an optional policy for player virtual libraries when Material moves, copies, or swaps queues. | L | Proposed; feasibility and policy undecided | [Queue transfers and player libraries](#queue-transfers-and-player-libraries) |

## Remote and streaming seeds

Currently, Lab first obtains seed metadata from the player's queue and passes
seed track paths to the native mixer. The mixer looks those paths up in
`bliss.db` for their analyzed features. A remote track displayed as a seed by
Lyrion is therefore not necessarily an acoustically usable Bliss seed.

On 14 November 2026, a Bandcamp queue produced visible seed titles with empty
artist names, followed by no new Bliss tracks. The log does not establish
whether every seed was absent from `bliss.db` or why the artist metadata was
empty; investigate both boundaries before selecting a solution. Some other
remote services are explicitly treated differently in Lab's current code.

Explore, without assuming equivalent coverage or quality:

- Resolve a remote recording to an **exact, confidently matched** analyzed
  local recording using available stable identifiers and metadata. Handle
  ambiguous matches, versions, missing metadata and unavailable IDs safely.
- Investigate whether legally and technically feasible temporary acoustic
  analysis of a remote track can supply a seed vector without adding the track
  to the user's library. Consider service terms, permissions, streaming access,
  latency, memory, cancellation, privacy and cache retention.
- Evaluate a clearly identified metadata/semantic fallback when acoustic
  evidence is unavailable. Do not describe a similar artist or track as an
  exact recording match, or as a Bliss acoustic comparison; decide whether
  such a fallback fits the product's Bliss-first behavior and should be opt-in.

Newly selected tracks must still respect the player's candidate library and
existing repeat and genre rules. Preserve the queue and keep DSTM able to
recover when no safe seed is available; do not silently start an unrelated
random mix. Report the seed source and failure reason clearly while preserving
established log formats. Test single and mixed local/remote queues, missing or
incorrect metadata, multiple versions, service failures, and player-specific
recovery with real examples before claiming support.

## Queue transfers and player libraries

Material offers move, copy and swap actions for player queues, including from
the long-press menu on the queue count and duration. The players can have
different assigned virtual libraries. Explore an opt-in Lab setting that can
also account for those player-library assignments during the transfer.

Questions to resolve:

- For **copy** or **move**, should the destination retain its own library or
  adopt the source player's library? If moving clears the source queue, should
  the source library remain unchanged, be restored, or follow another policy?
- For **swap**, should the two libraries follow their original queues in both
  directions, or stay with their players? What happens for an unset or inherited
  library, or a library that is no longer available?
- Can Lab reliably detect a successful transfer and its source, destination and
  operation through Lyrion events without modifying Material? Avoid inferring a
  transfer from unrelated queue changes; partial failures and concurrent actions
  must not silently change the wrong player's library.
- How should this interact with Material's player-library options, Lab's
  browser/player synchronization, multiple clients, synchronized players and
  DSTM requests already in progress? Define precedence and rollback/error
  handling, and make the scope of any preference clear to users.

This is an idea to investigate, not a claim that Material exposes the necessary
events or that the behavior can be implemented without changing it. Preserve
existing queue actions and playback when the option is disabled.
