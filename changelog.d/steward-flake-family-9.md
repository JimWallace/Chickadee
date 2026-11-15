### Changed

- **`docs/ci-flakiness.md` records Family 9.** The workbench shell e2e on chromium sometimes times out after a save, because the toolbar insert does not take effect. Two scheduled runs on `main` hit it, so it is not caused by a diff. The entry gives the tells and the handling.
