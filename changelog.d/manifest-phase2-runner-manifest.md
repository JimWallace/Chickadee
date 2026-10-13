### Changed

- **Runner manifest type (manifest v2, phase 2).** `Job.manifest` is now a `RunnerManifest`, which holds only the fields a runner reads. A worker read of a server-only manifest field no longer compiles, and a new manifest field reaches a runner only when it is added to `RunnerManifest`. The wire bytes are unchanged, so older runners and the runner's test-setup cache key are not affected. See `docs/manifest-format-v2.md`.
