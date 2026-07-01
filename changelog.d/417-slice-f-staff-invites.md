### Added

- **Self-serve instructor staff invites (#417 Slice F).** A per-course
  instructor can now add a co-instructor or TA to their own course directly
  from the Students tab — an **Add staff** disclosure takes a username or email
  and a role (TA / Instructor). If the identifier matches an existing account
  it is enrolled (or promoted) at that role; if no account exists yet, an
  SSO-style placeholder is minted (no local password) and adopted by username
  on the person's first login. Unlike the CSV bulk-enroll path — which records
  a pre-enrollment that seeds to `student` at login — a staff invite
  materializes the enrollment immediately so the chosen staff role sticks
  (`POST /courses/:courseID/staff`, `instructorInviteStaff`).

### Changed

- **TAs are read-only on the roster (#417 Slice F).** The Students tab now gates
  every mutating control — the per-row role dropdown, the unenroll / register
  buttons, the enrolment-mode selector, "Enrol from CSV", and the new "Add
  staff" form — on a `canManageRoster` flag (per-course instructor or admin), in
  both the server-rendered page and the poll-driven JS repaint. A TA still
  reaches the instructor area and sees the roster, but can no longer see
  controls whose `POST` the server already refused with a 403. Staff invites use
  the `.instructor` write floor (enrollment management stays instructor-only),
  not the `.ta` content floor.
