### Changed

- **Dependency updates land on their own.** `dependabot-auto.yml` regenerates the committed output a bump feeds (`Public/vendor`, the JupyterLite extension, the kernels) and enables auto-merge on every Dependabot pull request, so the required checks decide. A red update, a stalled one, a security alert Dependabot cannot fix, and a broken or expiring `RELEASE_TOKEN` each become an issue labelled `dependency-update-failed` with a brief for an agent (`dependency-failure.yml`, `dependency-health.yml`). See `docs/dependency-updates.md`.

### Fixed

- **Dependabot bumps `jupyterlite` and `jupyterlite-core` together.** The two pins must match, and bumped one at a time neither PR resolved under pip. Dependabot now also covers the JupyterLite extension, with `@jupyterlab/*` and `@lumino/*` grouped.

### Security

- **katex, sanitize-html and minimatch are past their advisories.** Their parents pinned them back, so Dependabot could not update them. The extension forces katex 0.19 and sanitize-html 2.18 with yarn `resolutions`, and the root forces minimatch 11 with npm `overrides`. All three are build-time only, and the shipped bytes do not change.
