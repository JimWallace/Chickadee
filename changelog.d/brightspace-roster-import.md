### Added

- **Grade students who haven't logged into Chickadee yet (LEARN roster import +
  override-only sync).** A new **"Import students from LEARN"** action on the
  instructor LEARN tab provisions the bound course's classlist as real,
  enrolled, passwordless Chickadee student accounts — caching each member's D2L
  UserId + student number from the classlist so grade sync resolves with no
  lookup. Combined with a new override-only push wired into **"Sync now"**, an
  instructor can set a grade override on a student with **no submission** and
  have it sync to LEARN (the result-based sweep only ever saw submitters). This
  enables grading non-submitters and exercising grade sync end to end.

  Safe on a live class: when an imported student later logs in via SSO they
  **adopt** their provisioned account in place (matched by the IdP-authoritative
  username), inheriting its cached BrightSpace ids and any grades, instead of
  colliding on the unique username or creating a duplicate. Only never-logged-in
  `learn-roster` shells are adoptable; real local/SSO accounts are never claimed.
