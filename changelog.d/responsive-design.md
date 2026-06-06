### Added

- **Responsive web UI for phones and tablets.** Summary/list pages (student and
  instructor dashboards, submission history) hide non-essential columns on small
  screens; the per-student extension / grade-override flow is usable on a phone;
  dense admin tables (runner, audit) scroll horizontally; and the notebook editor
  is gated to tablet-and-up with an "open on a larger screen" notice on phones.
  Built intrinsic-first (`min()` / `clamp()` containers, viewport breakpoints only
  where needed) so the desktop layout is unchanged. See
  `docs/responsive-design-plan.md`.
