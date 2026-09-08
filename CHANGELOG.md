# Changelog

## 0.6.0 - 2026-09-08

- Remove the Lab-owned play-count setting now that play-count influence is
  configured and implemented by Bliss Mixer.
- Inherit Bliss Mixer's Static Weights, EIF, or Adaptive Weightings strategy
  and its shared Last.fm artist/play-count candidate refinements.
- Apply the Lab-owned Last.fm recording-similarity guidance to candidates from
  all three strategies; learned-matrix influence remains Adaptive-only.

## 0.5.0 - 2026-09-06

- Rename the companion plugin from Bliss Mixer Extensions to **Bliss Mixer Lab**.
- Switch the technical plugin identity, Perl namespace, command namespace,
  preferences, web paths, icon path, package names, and release metadata from
  `BlissMixerExt`/`blissmixerext` to `BlissMixerLab`/`blissmixerlab`.
- Publish platform packages as `lms-blissmixer-lab-*` archives with the
  sidecar mixer installed as `bliss-mixer-lab`.

## 0.4.3 - 2026-09-04

- Bundle bliss-mixer 0.10.1, built against bliss-mixer-core revision
  `a605edc2b61b525bd75bb3d350fd4b41235cf5d6`.

## 0.4.2 - 2026-09-04

- Place the three Lab track context actions, in their established order,
  immediately after Bliss Mixer's three actions.

## 0.4.1 - 2026-09-04

- Add INFO logs for all three Lab context actions, including the effective
  strategy, filters, seeds, resolved results, and failures.
- Add DEBUG logs for request parameters, seed/result paths, raw API responses,
  and HTTP/result/total timing.

## 0.4.0 - 2026-09-04

- Add distinct `Create bliss mix (Lab)` actions for track, album, and artist
  context menus.
- Add `Similar tracks (Lab)` and `Similar tracks by artist (Lab)` track
  actions, routed exclusively through the sidecar mixer.
- Pass the configured adaptive-weighting strategy and learned-matrix influence
  to interactive similarity requests while retaining all upstream filters.
- Extend the upstream-drift workflow to track the adapted interactive command,
  menu, API-response, and request-payload routines.

## 0.3.2 - 2026-09-03

- Add missing (mandatory) string token to strings.txt

## 0.3.1 - 2026-09-03

- Restore the historical centered Last.fm selection columns and distinguish
  artist `(a)`, track `(t)`, and combined `(a+t)` endorsements directly in the
  first column.
- Keep numeric support and weight calculations at debug level, while making
  the INFO summary report both artist and track matches as shares of the pool.
- Continue serving mixes while upstream analysis updates `bliss.db`, deferring
  one mixer refresh until analysis has finished.

## 0.3.0 - 2026-09-03

- Add bounded Last.fm similar-track guidance for local Bliss candidates, using
  recording MBIDs with normalized artist/title fallback.
- Collect track and artist evidence concurrently, accept partial results, and
  fall back after a short deadline without blocking DSTM playback.
- Combine track similarity with the existing artist endorsement and optional
  play-count influence without further enlarging their shared candidate pool.
- Preserve `bliss-only` and `last.fm-endorsed` diagnostics in combined
  selection logs, add recording evidence and play counts, and align every
  pipe-delimited column.
- Make Companion status collapsible and keep each section's separator inside
  the section so it disappears when the section is folded.
- Change Play-count influence to one-point slider steps and remove candidate-
  pool implementation details from its user-facing description.

## 0.2.0 - 2026-09-03

- Add a bidirectional play-count influence setting: negative values favor
  less-played tracks and positive values favor frequently played tracks.
- Expand the Bliss candidate pool progressively with the absolute play-count
  influence, while sharing Last.fm's existing 10x pool when both are enabled.
- Disable play-count influence when LMS was started with `--nostatistics` and
  explain how listening statistics are enabled.
- Group experimental mix settings and metric-learning controls into distinct,
  collapsible settings sections.
- Install the learner under its canonical `bliss-learner` name; only the mixer
  needs an Lab-specific filename for side-by-side process isolation.

## 0.1.6 - 2026-09-03

- Show the same live metric-learning details as BlissMixer: start time,
  elapsed duration, and the learner's current training phase and progress.
- Poll learner status every second while training and return to slower idle
  polling after completion.
- Route native learner notifications to the independent `blissmixerlab`
  command without changing the original BlissMixer notification contract.
- Clarify that the displayed compatible BlissMixer version is the installed,
  enabled version detected live by LMS.

## 0.1.5 - 2026-09-03

- Rename the user-facing plugin to **Bliss Mixer Lab**.
- Describe it as **Experimental and early-access extensions for Bliss Mixer**
  while preserving the `BlissMixerLab` technical identity and **Bliss (Lab)**
  Don't Stop the Music provider.

## 0.1.4 - 2026-09-03

- Restore the established `learned_matrix.json`, `training_triplets.json`, and
  `blissmixer-triplets-<timestamp>.zip` learning-data filenames.
- Migrate data created by BlissMixerLab 0.1.0-0.1.3 to the canonical filenames
  without overwriting an existing canonical file.

## 0.1.3 - 2026-09-03

- Match BlissMixer's persistent training-data backup folder control.
- Match BlissMixer's icon-only backup restore picker and automatic restore
  behavior after selecting a ZIP file.

## 0.1.2 - 2026-09-02

- Restore the LMS slider control for Learned matrix influence.
- Remove the mixer port from the user-facing settings and automatically select
  an available loopback port for the experimental mixer process.

## 0.1.1 - 2026-09-02

- Fix the LMS string catalog delimiters so the plugin name and settings labels
  are localized instead of appearing blank or as raw string IDs.
- Validate the string catalog format and every settings-page localization token
  in CI.

## 0.1.0 - 2026-09-02

- Create a standalone `BlissMixerLab` plugin identity.
- Add the independent **Bliss (Lab)** Don't Stop the Music provider.
- Reuse upstream Bliss Mixer preferences and its read-only analysis database.
- Isolate experimental mixer and learner binaries under Lab-specific names.
- Move the similarity survey, triplets, backups, and learned matrix into the
  sidecar namespace.
- Add an automated, checksum-verified release workflow that publishes all three
  platform packages and updates the LMS plugin feed.
