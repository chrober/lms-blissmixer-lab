# Binary provenance

Deployable executables are not committed to this repository. Release packages
consume checksum-verified assets from the native component repositories.

- Mixer release: `v0.11.7`
- Mixer commit: `7ab1ec7566fce6d21183e468c0c440c34fa42b1a`
- Learner release: `v0.1.3`
- Learner commit: `0644a912677b400ad1ab07a60e83e24c5049826d`

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
