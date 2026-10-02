### Changed

- **The dead `setup` parameter of `AssignmentLanguage.resolve(for:manifest:)` is gone.** The wrapper discarded its setup at every one of its fifteen call sites and forwarded to Core's `resolve(manifest:)`; the sites call that directly now, and the wrapper file with it. The two stale headers the issue named were already corrected by #1725 (#1733).
