### Fixed

- **Browser-wasm re-vendor no longer loses the post-merge push race.** The
  `runner-wasm-vendor.yml` job rebuilds the in-browser grading wasm whenever
  RunnerCore changes on `main` and pushes the artifact back — but
  `auto-release.yml` pushes its `chore(release)` commit to `main` in the same
  post-merge window, and the slower wasm job lost a plain `git push` on every
  RunnerCore-touching merge, leaving the re-vendor unpushed until a manual
  re-trigger. It now rebases its artifact-only commit onto the latest `main`
  and retries (up to 5×), so the artifact lands on its own.
