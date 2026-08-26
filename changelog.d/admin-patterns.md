### Changed

- **The admin area follows one set of patterns.** Eight flat tabs group into
  five (Overview and Health Alerts stay top-level; the rest become People, Data
  and Integrations menus, reusing the site's existing nav-dropdown idiom). Every
  admin setting now reads as one — a label, a note saying what saving does, and
  the button beside the field it saves — rather than a placeholder standing in
  for a label in a section heading. The audit log and alert firings share one
  log/event shape: when, actor, event, outcome, and the payload behind a closed
  disclosure. The runner detail page leads with the page name and a status block
  that appears only when something is wrong, with its ten measurements moved
  below into a facts list. Admin tables now choose which columns earn phone
  width using the existing shared column classes.
- **Destructive confirmations name the consequence.** Each one states the scale,
  then what is kept, then the way back — "Archive HLTH230? 96 students lose
  access immediately. Submissions, grades and audit records are kept, and you
  can un-archive from the course page." — instead of naming only the verb.

### Added

- **Audit entries carry an outcome.** A failed login, a lockout and a detected
  refresh-token reuse now read as `failed` beside the 63 actions that simply
  succeeded, so the events an admin scans the log for stand out. Derived by an
  exhaustive switch, so a new action has to answer the question at the compiler.
