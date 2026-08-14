### Fixed

- **Two accessibility defects on the dashboards and the alerts page.** The
  clickable statistic cards on the admin and instructor dashboards announced
  themselves to screen readers with a role their element does not permit, so
  assistive software could describe them incorrectly; they are now built from an
  element that carries the role properly, with no visual change. The alerts page
  skipped a heading level, which breaks heading-based navigation for screen
  reader users; its sections now sit at the level the rest of the site uses.
  With these, the site has no remaining accessibility violations of any severity
  in the automated scan.
