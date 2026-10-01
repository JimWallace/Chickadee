### Changed

- **The LEARN tab's view model is assembled by `BrightSpacePagePresenter`.** The grade-item rows, the per-student sync rollup, the roster-readiness panel and the facts card moved out of the 1,100-line BrightSpace route extension into a service over the database, so they are testable without a request. The handlers keep the request work. Slice 1 of #1654.
