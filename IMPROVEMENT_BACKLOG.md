# Bliss Mixer Lab improvement backlog

This is a re-orderable list of proposed work. Move complete rows to change
priority; sizes are rough engineering estimates, not time commitments.

| Improvement | Intended outcome | Size | Status | Details |
| --- | --- | ---: | --- | --- |
| Keep DSTM working during library scans | Continue adding eligible tracks while Lyrion scans, without blocking playback or violating the selected library. | L | Critical requirement; not yet verified | [DSTM during library scans](#dstm-during-library-scans) |
| Continue DSTM after switching player libraries | Investigate and reliably continue an existing queue using candidates from the newly selected player library, including recovery after inventory failures. | L | Investigation needed | [Switching libraries during playback](#switching-libraries-during-playback) |
| Continue DSTM from non-library tracks | Let Bliss (Lab) continue from eligible Bandcamp, YouTube, or other remote tracks when a reliable seed can be established. | XL | Research and design needed | [Remote and streaming seeds](#remote-and-streaming-seeds) |
| Carry player libraries with transferred queues | Explore an optional policy for player virtual libraries when Material moves, copies, or swaps queues. | L | Proposed; feasibility and policy undecided | [Queue transfers and player libraries](#queue-transfers-and-player-libraries) |

## DSTM during library scans

**Requirement: Bliss (Lab) DSTM must continue working while a Lyrion library
scan is active.** A scan must not indefinitely prevent eligible tracks from
being added, freeze playback or the UI, or require a server restart to recover.

The shared candidate-inventory implementation must support this requirement
while preserving the selected player-library scope and existing genre and
repeat rules. Design and test a safe way to provide candidates even when no
usable snapshot was previously built; do not silently broaden the library or
admit invalid tracks. Consider how to use a previously verified snapshot during
database changes, handle removed or unavailable tracks, and refresh after the
scan. Do not assume a stale snapshot is always safe. Transient database locks or
worker failures must be handled and reported, with bounded retries and
automatic recovery.

On 14 November 2026, DSTM inventory capture repeatedly failed with an empty
worker response while a scan was active; Lyrion also reported a database lock.
The relationship between the scan, lock and worker failure remains unproven.
See [Switching libraries during playback](#switching-libraries-during-playback)
for the observed sequence.

After the scan on 14 November, two completion notifications queued the same
two previously requested scopes. At 19:30, the refresh of “Alles ohne
Hörbücher” (`4d2ba37f`) detected that `bliss.db` had changed during validation
and failed safely. Christmas (`695435a5`) then refreshed successfully, and a
retry of “Alles ohne Hörbücher” also completed. This demonstrates refresh
retry, not by itself DSTM recovery or continued operation during a scan.

At 19:37, a later Lab DSTM attempt using three Sue Foley tracks as seeds:

- Restarted the native mixer after detecting a changed `bliss.db`, then
  reported it ready.
- Reported a cached shared inventory for Christmas at 19:37:25 and applied
  the configured Christmas-exclusion override. This is a Lab cache hit; it
  does not establish cross-host reuse or identify which operation built it.
- Sent the mixer request at 19:37:54, around 29 seconds after logging the
  candidate library. The mixer scored 852 tracks and reported 20 usable, no
  genre rejections, and 256 ms native processing time.
- Selected Alanis Morissette’s “O Tannenbaum” and Halford’s “Light of the
  World” at 19:37:58, roughly 45 seconds after the DSTM request began. A later
  read-only inspection confirmed both tracks in the Wohnzimmer queue following
  the Sue Foley album. This verifies this post-scan continuation, not operation
  while a scan is active.

The debug-only “would have chosen” comparisons subsequently listed tracks
outside Christmas for the static, isolation-forest and alternative adaptive
strategies. They are hypothetical comparisons, not the two actual additions.
The comparison request builder does not pass the candidate-library snapshot;
investigate whether comparisons should use the same scope so their results are
meaningful and cannot be mistaken for actual selected tracks.

Investigate the approximately 11 seconds from DSTM start to the cache hit and
the subsequent approximately 29-second gap before the mixer request; do not
attribute either delay to the shared inventory without further measurements.
The code prepares an artist-repeat identity snapshot between the library log
and request log; determine whether this accounts for the gap. Measure the full
path, including host-side preparation and responsiveness, and verify cross-host
reuse after refresh.

Verify on the Pi with both warm and missing snapshots, active scans and
concurrent library changes. Check that eligible in-scope tracks are actually
added, playback and the UI stay responsive, other players are unaffected, and
normal freshness and refresh behavior resumes after the scan.

## Switching libraries during playback

On 14 November 2026, while an album from “Alles ohne Hörbücher” was playing,
the browsing and player library were switched to “Christmas”. The expected
behavior was to retain the existing queue as seeds and add eligible Christmas
tracks from the newly selected player library. Manually adding Christmas tracks
afterward did not restore the expected continuation.

### Reproduction sequence

The following records the observed sequence; repeatability and the precise
conditions responsible for each failure still need to be established.

1. With the shared-inventory development builds installed, enable Bliss (Lab)
   DSTM for a player and select “Alles ohne Hörbücher” as its library.
2. Start playing a local album from that library, leaving the album's tracks
   in the queue as DSTM seeds.
3. While the album is playing, switch both the Material browsing library and
   the player's library to “Christmas”. The player library is configured to
   allow Christmas tracks despite the normal Christmas exclusion.
4. Let DSTM attempt to extend the queue. Expect it to preserve the existing
   queue and select eligible additions from Christmas; in the observed run it
   added none and reported that the genre filter rejected all candidates.
5. Manually add individual Christmas tracks to the queue and trigger subsequent
   DSTM attempts. In the observed run these also added nothing, but failed at
   shared-inventory capture instead. Capture the server log and any worker
   error details; do not assume this second failure always occurs.

The Pi's development build logged two distinct failures:

- At 19:06, the shared inventory was built for Christmas, the Christmas
  exclusion was overridden, and the native mixer scored 849 candidates; all
  849 were rejected by the genre filter. Investigate the interaction between
  source-derived genre restrictions and the new candidate library, rather than
  assuming the library switch itself failed.
- At 19:08–19:09, subsequent attempts, including with Christmas seeds, failed
  earlier: the shared-inventory client received empty or malformed JSON while
  capturing the candidate library. A Lyrion SQLite database-lock error occurred
  nearby; whether it caused the worker failure is not yet established.

The “Auto-mixing from random tracks in current playlist” lines in this trace
come from collecting comparison seeds for adaptive debug diagnostics; they do
not establish that tracks were selected or added to the queue.

Investigate both failures and their relationship to shared-inventory work.
Define how a new player library interacts with seed genres and Christmas
exclusions, preserve the existing queue and scope restrictions, and make sure
DSTM can recover after temporary worker/database failures. Test switches in
both directions, mixed old/new-library seeds, explicit genre settings, empty
results, concurrent scans and subsequent retries on the affected player.

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
