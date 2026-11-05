### Security

- **The dependency rebuild no longer shares a job with the push token.** `dependabot-auto.yml` and `revendor-kernels.yml` ran the bumped packages' install and build scripts, then pushed with a personal access token in a later step of the same job. A build step can reach a later step through `$GITHUB_PATH`, `$GITHUB_ENV`, a git hook or `.git/config`. The build now runs in a job with no secret and writes a patch artifact. A separate job checks that every file in the patch is regenerated output (`scripts/regenerated-patch.sh`), then commits and pushes it.
