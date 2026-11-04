### Fixed

- **Mutation sweep: shard 5 no longer times out.** Muter guards each mutant
  with a call that rebuilds the whole process environment, once per guard and
  per call, so a mutated hot loop (AvatarSpec's weighted pick) made every
  mutant in the shard end at the 15-minute limit, and the job was cancelled at
  three hours for three weeks running (#2810). A second patch to the pinned
  Muter, `Tools/mutation/0002-read-environment-once.patch`, makes each mutated
  file read the environment once. `scripts/mutation-run.sh` now applies every
  `Tools/mutation/*.patch` in order, and the `Mutation-testing probe` workflow
  now builds the patched tool, which it never did before, and checks that the
  guards read the cached copy.
