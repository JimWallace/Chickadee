### Fixed

- **The per-instructor LEARN Connection panel is back (#1114).** The runbook's
  documented flow — "Connect my LEARN account", "Use my account for this
  course", "Disconnect", "Link course", and the connection test — lost its UI
  in an earlier LEARN-tab rework, leaving five working handlers with no entry
  point and half the view context computed but never rendered. The panel is
  restored on the LEARN tab; the view context is grouped into nested
  `account` / `syncIdentity` panels (killing the duplicated 26-field empty
  variant), and the dead log/summary/readiness-rollup aggregation that no
  template consumed is dropped from the page load.
