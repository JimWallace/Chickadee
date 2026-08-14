### Changed

- **Auto-refreshing tables render on the server (audit S3).** The admin Users,
  admin Runners and instructor Students tables now refresh by swapping in rows
  rendered from the same Leaf partial the page itself uses, instead of
  rebuilding every row from hand-written HTML strings in a page script. The
  duplicate markup — role dropdowns, CSRF fields, icons, a whole
  register-student panel — is gone, so a table's background refresh can no
  longer drift from what the page renders. Polling behaviour (pausing on a
  hidden tab or while a control has focus, and not counting as session
  activity) is now one shared implementation rather than three.

### Fixed

- **Runner "Offline" badges show immediately.** The offline state is computed
  on the server, so it appears on first paint; previously it was only worked
  out during a background refresh, leaving a freshly loaded dashboard showing
  no offline runners until the first tick.
