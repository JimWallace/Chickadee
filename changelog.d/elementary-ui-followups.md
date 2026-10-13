### Fixed

- **The enrol page says why a student is back on it.** Saving with no course selected redirects to `/enroll?error=none_selected`, but the page never read the code, so "Please select at least one course to continue." never showed.
- **Headings no longer skip a level on Connected agents and the notebook page.** The Connected agents title is an `h1`, and the notebook page has a visually hidden `h1`.

### Changed

- **One component writes each row's More actions menu.** `RowMenu(for:)` replaces 16 copies of the same markup, and a SwiftLint rule keeps the shell in it. The admin and instructor dashboards share `MetricsDiagnosticCard`.
- **State banners use the warning style.** The OAuth first-time warning (now without an emoji), "MCP is inactive" and the LEARN "Grade sync is paused" banner are warning banners.
- **Small UI clean-ups.** "Log in with UWaterloo"; shorter notes on the editor reset, slip-day and roster pages; the assignment editor's language note no longer says Chickadee works the language out; the audit filter's Clear is a button; shared classes replace page-only ones on the slip-day confirm card, the GitHub options and the workbench's stale-notebook notice.
