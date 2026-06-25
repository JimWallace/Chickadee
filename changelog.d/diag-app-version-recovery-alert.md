### Changed

- **Editor kernel alerting now targets the genuinely-stuck student.** The
  `editorKernelHang` health-alert rule is replaced by `editorKernelUnrecoverable`,
  which fires on `recover_failed` reports — a student whose kernel hung, was
  auto-rebooted by the editor, and hung *again* — instead of on every post-idle
  `exec_hang` (the vast majority of which auto-recover and never actually block
  the student). `exec_hang`s are still collected in `client_diagnostics` /
  `get_browser_diagnostics` for analysis; they just no longer page the operator.
  Default threshold is 2 in 60 min, tunable via `ALERT_EDITOR_UNRECOVERABLE_THRESHOLD`
  / `ALERT_EDITOR_UNRECOVERABLE_WINDOW_MINUTES` (the former `ALERT_EDITOR_HANG_*`
  names still work).

### Added

- **Browser diagnostics carry the page-build version.** Every client diagnostic
  (editor errors, kernel breadcrumbs including `exec_hang` / `recover_failed`, the
  submit funnel, and the freeze beacon) now records the `app_version` of the page
  build that emitted it, surfaced as a `byAppVersion` breakdown in
  `get_browser_diagnostics`. A failure concentrated on an *old* version is a
  stale-tab / cached-bundle symptom (that browser never re-fetched the fixed
  bundle); one on the *current* build means a deployed fix is incomplete — turning
  "is this hang old cached code or a live bug?" from a guess into data.
