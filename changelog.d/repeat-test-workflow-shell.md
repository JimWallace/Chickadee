### Fixed

- **The repeat-test workflow runs its step under bash and counts correctly.** The first dispatch of `repeat-test.yml` ran all 25 repetitions green and then failed on `Bad substitution`: the container's default shell is dash, which has no `PIPESTATUS`. The step now names `bash`. Its summary also counted the `Test run started.` line as a matched test and counted only repetitions 2 and later; it now reports the tests matched and the total test runs across every repetition.
