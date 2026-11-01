# Binary provenance

Deployable executables are not committed to this repository. Release packages
consume checksum-verified assets from the native component repositories.

- Mixer release: `v0.11.6`
- Mixer commit: `e9955d5f5a14059b30381f57c0bc5296f2846357`
- Learner release: `v0.1.2`
- Learner commit: `959f2c1222c207f7d40c90187a4884a73422aec8`

The release workflows reject replacing assets when the tag and build commit
disagree. Each native release also publishes a source archive for that commit.

The plugin release workflow downloads the five platform assets and their
`.sha256` files from each release, verifies them, and installs them under these
the Lab-specific mixer name and the learner's canonical name:

- `x86_64-linux/bliss-mixer-lab` and `bliss-learner`
- `aarch64-linux/bliss-mixer-lab` and `bliss-learner`
- `armhf-linux/bliss-mixer-lab` and `bliss-learner`
- `mac/bliss-mixer-lab` and `bliss-learner`
- `windows/bliss-mixer-lab.exe` and `bliss-learner.exe`

Update and commit the release tags and source commits together before publishing
a plugin version with newer native components.
