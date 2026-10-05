# Bliss Mixer Lab

BlissMixerLab is an independent companion plugin for
[Lyrion Media Server](https://lyrion.org/) and the upstream
[Bliss Mixer](https://github.com/CDrummond/lms-blissmixer) plugin. It provides a
temporary staging area where experimental and early-access extensions can be
tested by interested users before they are proposed for inclusion in Bliss
Mixer.

BlissMixerLab is installed alongside Bliss Mixer and does not replace or modify
it. Features may be added, changed, or removed as experiments evolve or move
upstream.

## Current features

This list is intentionally ephemeral and describes what the staging plugin
currently contributes:

- A preference-learning survey and native learner that produce a learned
  similarity matrix, including configurable matrix influence and training-data
  backup and restore.
- A separate **Bliss (Lab)** Don't Stop the Music provider that honors Bliss
  Mixer's configured strategy, filters, and candidate-selection refinements.
  It adds:

  - Learned-matrix weighting with configurable influence when Bliss Mixer uses
    **Adaptive Weightings**.
  - Optional guidance-provider integration through the shared host contract.
    Lab discovers compatible providers at runtime, keeps them disabled until
    explicitly enabled, and applies their bounded signals only to the existing
    Bliss-derived candidate pool. Provider capabilities, settings, acquisition
    paths, and policy semantics remain owned by the provider plugins.

  The Lab README intentionally does not enumerate individual providers. New
  compatible providers can be added without changing this host documentation.
- **Create bliss mix (Lab)** actions for tracks, albums, and artists, plus
  **Similar tracks (Lab)** and **Similar tracks by artist (Lab)** actions. These
  use the separate Lab mixer and respect the configured mixing strategy,
  including adaptive weighting and the learned matrix.

## Responsibilities

- Upstream Bliss Mixer analyses the music library and owns `bliss.db`.
- BlissMixerLab reads that database and the upstream mix preferences.
- BlissMixerLab owns the runtime processes, preferences, and data needed by its
  staged extensions.
- Guidance providers are separate passive plugins. Lab invokes enabled
  providers through the shared host contract for the DSTM candidate pool;
  providers do not replace Bliss similarity or select tracks independently.
  See
  [GUIDANCE_PROVIDER_HOST_INTEGRATION.md](GUIDANCE_PROVIDER_HOST_INTEGRATION.md)
  for the staged host integration and failure behavior.
- The plugins remain separately registered and operate side by side.

BlissMixerLab requires a compatible original Bliss Mixer installation and a
supported Lyrion Music Server version.

## Installation

The recommended installation method is
[chrober's LMS Plugin Repository](https://github.com/chrober/lms-plugins),
where the current repository setup and installation instructions are
maintained. Add its feed as an additional repository in Lyrion Media Server:

```text
https://raw.githubusercontent.com/chrober/lms-plugins/main/repo.xml
```

Then install **Bliss Mixer Lab** through the LMS plugin manager and
restart LMS. The repository selects the appropriate platform-specific package,
including `bliss-mixer-lab` and `bliss-learner`, for the server.

Enable both Bliss Mixer and Bliss Mixer Lab. Run library analysis from
the upstream Bliss Mixer settings, configure experimental options on the
BlissMixerLab settings page, and select **Bliss (Lab)** under Don't Stop the
Music.

For development, place or symlink the `BlissMixerLab` directory in the LMS
plugins directory and run:

```text
python download-binaries.py
```

## Compatibility and isolation

The sidecar deliberately does not register an analyser, importer, Bliss Mixer
URL protocol, or replacement context-menu handlers. Its uniquely named Lab
context-menu providers coexist with the upstream actions. Its mixer listens
only on a separate automatically selected loopback port. It checks whether the
upstream analyser is active and reloads its mixer when `bliss.db` changes.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the staging and migration model.

## Testing

Every push and pull request runs repository validation, feed-update unit tests,
and the Perl plugin regression suite. The Perl tests exercise the sidecar's
upstream compatibility gate, DSTM identity and port isolation, inherited mixer
preferences, survey persistence and backup/restore, and learned-matrix
replacement behavior. It also covers provider integration, partial provider
failures, and integration with upstream candidate reranking. Release publication
runs the same test gate.

The separate `BlissMixer DSTM drift` workflow checks the current upstream
implementation every Monday and whenever the DSTM implementation or drift
configuration changes. Directly cloned routines must remain token-equivalent
after plugin-identity normalization. Intentionally adapted routines are compared
with the last reviewed upstream commit. Significant changes fail the workflow;
scheduled failures create or update a single review issue with per-routine
diffs.

After reviewing an upstream change, incorporate or intentionally reject each
relevant change and then advance `reviewed_upstream_commit` in
`compat/dstm-drift.json`. Do not advance the commit merely to silence the check.

On a Debian-based development system, run the complete plugin suite with
`prove -l tests` after installing the Perl dependencies listed in
`.github/workflows/validate.yml`.

## Release and publishing workflow

Pushing a semantic version tag runs `.github/workflows/release.yml`. It validates
the plugin, reads the pinned native releases from
`BlissMixerLab/Bin/SOURCE.md`, downloads and verifies every SHA-256 file, and
creates separate Linux, macOS, and Windows plugin packages. It publishes those
packages and their SHA-1/SHA-256 files as a GitHub Release, then updates the
three platform entries in `chrober/lms-plugins`.

Native release downloads and the feed update use the repository secret
`LMS_PLUGINS_TOKEN` (the legacy name `MS_PLUGINS_TOKEN` is also accepted) with
read access to the native repositories and contents-write access to
`chrober/lms-plugins`. A manual run with `dry_run=true` builds inspectable
workflow artifacts without publishing or changing the feed.

## Attribution and licence

This project contains code adapted from Craig Drummond's GPLv3-licensed
[lms-blissmixer](https://github.com/CDrummond/lms-blissmixer). The metric
learning work is based on `bliss-metric-learning` by Polochon-street.

BlissMixerLab is distributed under the GNU General Public License v3. See
[LICENSE](LICENSE).
