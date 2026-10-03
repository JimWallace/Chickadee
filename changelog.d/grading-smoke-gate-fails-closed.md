### Fixed

- **The browser grading smoke gate no longer passes when change detection fails.** `r-grading-smoke-gate` read only the smoke result, so when the `changes` job failed the smoke was skipped and the required check went green with nothing checked. It now fails closed on the `changes` job, as `editor-smoke-gate` does (#1979).
