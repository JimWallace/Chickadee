### Fixed

- **UI defect sweep (audit S0).** The connected-agents empty state no longer
  spans a phantom column for non-admins; the runner-detail poll now sends
  `X-Background-Refresh` (so watching the dashboard no longer holds the idle
  session open) and pauses while the tab is hidden; the LEARN re-push button
  gained its missing `aria-label`; static state banners and post-redirect
  error banners now carry `role="status"` / `role="alert"` respectively; a
  dead `relative-time.js` include was removed from the assignments page; and
  the grade-override popover on the assignment-submissions page now gets the
  same viewport-clamped floating as its course-page sibling — delegated, so
  popovers rebuilt by a background poll repaint keep floating too.
