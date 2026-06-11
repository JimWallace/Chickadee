### Fixed

- **Phone/tablet overflow on admin & instructor pages ("Phase 3b").** A live
  responsiveness audit (headless, 375px/768px — see
  `docs/responsiveness-audit-2026-06.md`) found seven pages overflowing a
  phone viewport: `/admin`, `/admin/users`, `/admin/mcp`, `/agents`,
  `/admin/storage`, `/admin/retention`, `/admin/alerts` (plus the BrightSpace
  page statically). All their tables now use the `.table-scroll` wrapper, and
  the page-local fixed-width / no-wrap rules (`.toolbar--nowrap`,
  `.alerts-webhook-input`, `.retention-actions`, `.bs-grade-form`,
  `.mcp-username-input`, `.students-filter`) relax below the phone
  breakpoint. Re-run of the live audit: zero horizontal overflow on every
  reachable page at 375px and 768px; desktop unchanged.
- **Extension/grade-override popover fits a phone.** The
  `course-student-submissions` action panel drops into static flow ≤640px
  (matching the assignment-submissions form), and the instructor dashboard
  publish popover loses its 260px floor on phones.
- **iOS zoom-on-focus.** Form inputs are 1rem on phones so iOS Safari no
  longer zoom-and-pans when focusing a field.
- **Notebook editor no longer boots in the background on phones.** ≤640px the
  hidden JupyterLite iframe's eager navigation is aborted and `notebook.js`
  skips the preflight/watchdog/mount entirely (reloading if the viewport
  grows past the breakpoint) — previously the full JupyterLite + Pyodide
  stack downloaded behind the "open on a larger screen" notice.
