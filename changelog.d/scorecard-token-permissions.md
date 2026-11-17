### Security

- **Workflow write scopes move to the job.** `auto-release`, `runner-wasm-vendor`, `kernel-currency`, `mirror-images` and `rerun-failed` now declare `permissions: {}` at the top and grant each write on the one job that needs it, so a job added later starts with no write token. This clears the five workflow-level OpenSSF Scorecard `TokenPermissions` alerts.
- **The vendor and smoke scripts install from their lockfiles.** `scripts/setup-vendor.sh` and `scripts/browser-grading-smoke.sh` run `npm ci`, not `npm install`, so they install exactly what `package-lock.json` pins (Scorecard `PinnedDependencies`).
