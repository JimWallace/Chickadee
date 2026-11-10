### Added

- **An arm64 runner image for a bonus runner on a Mac (spike).** A new
  workflow, `runner-arm64-image.yml`, builds
  `ghcr.io/jimwallace/chickadee-runner` for `linux/arm64` on each release tag.
  It checks that the runner starts in its sandbox with job cgroups, as uid 999
  with no capability, and detects every language. It is separate from the
  production image and blocks no deploy. `deploy/chickadee-runner-update.sh`
  takes a new `--image-repo` flag, so an Apple Silicon host follows the
  server's release with that image. `docs/mac-runner.md` covers sizing under
  Docker Desktop.
