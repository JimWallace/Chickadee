### Added

- **Per-assignment built-in award toggles.** A "Built-in Awards" card on the
  assignment edit page lists Chickadee's built-in awards — the per-submission
  Ace / Rally / Tenacious / Swift and the competitive Pathfinder / Trailblazer /
  Fastest / Minimalist class records — with an on/off switch each. Disabling one
  (e.g. turning the competitive class records off for a collaborative course)
  stops it being awarded and hides it on the submission page, history, and
  dashboard. Persisted in the manifest as `disabledBuiltInAwardIDs`.

### Fixed

- **Authored achievements no longer survive only until the next suite edit.**
  The suite-rebuild path (`makeWorkerManifestJSON`) built a fresh manifest that
  dropped the `achievements` array, so authoring a class goal or badge and then
  editing the test suite silently wiped it. The rebuild now preserves
  achievements (and the new built-in-award toggles).
