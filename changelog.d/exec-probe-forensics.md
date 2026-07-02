### Changed

- **Exec-hang probe forensics (`editor-exec-check.mjs`).** Hang iterations
  now capture the failing-resource URLs behind console errors, every >=400
  response and failed request, and the cell prompt/focus state; green
  iterations report their 4xx/console-error base rate so noise can't
  masquerade as a hang correlate. A second-press discriminator separates a
  new `lostDispatch` class (first Shift+Enter lost to a post-idle focus
  race, kernel healthy — student-facing) from the sustained-busy deadlock
  the probe hunts; only the deadlock class fails the leg.
