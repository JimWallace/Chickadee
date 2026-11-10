### Fixed

- **The page render tests no longer crash the test host on macOS.** A debug build copies each view's stored fields through Elementary's nested render frames. `PageRequestContext` and the account page's avatar picker were each about 1 KB, so rendering the account page needed 524 KB and overflowed a test thread’s 512 KB stack. Both now keep their values behind a shared reference. The account page now needs 365 KB, and the deepest page (the workbench) needs 390 KB. `docs/elementary-spike.md` (trap 8) records the measurements and the rule.
