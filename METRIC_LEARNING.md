# Metric learning in BlissMixerLab

The similarity survey presents three randomly selected analysed tracks. The
listener chooses the odd track out, producing a triplet where two tracks are
similar and the third is dissimilar. Triplets are stored by relative filename
in `training_triplets.json`.

After at least ten triplets have been collected, `bliss-learner` reads the
upstream `bliss.db` and trains a 23-by-23 Mahalanobis distance matrix. Training
first writes `learned_matrix.json.new`; BlissMixerLab activates it only
after the learner exits with a produced result.

At mixer startup, `bliss-mixer-lab` receives the matrix through `--matrix`. For
adaptive multi-seed requests, `learnedblend` controls the blend of the learned
and variance-derived matrices. For a single seed, the learned matrix is used
directly.

The survey and learner are deliberately sidecar-owned. They do not add commands,
settings, files, or callbacks to the upstream Bliss Mixer namespace.
