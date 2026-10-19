# Lab Groups and In-Lab Sessions

Design note for student groups inside a course, built for the lab room: a
section of about 25 students, one TA, one projector, one time slot. The goal is
that every class activity Chickadee already has (docs/class-activities.md,
docs/class-composite.md, docs/collaborative-class-assignments.md) can run
once per lab group, in that group's room, on that group's clock, with that
group's board on the projector. Grades, deadlines and roster scoping are not
the goal. They are listed at the end as things the same model can carry later.

Read **The model** and **Decisions** before you touch code. Each slice is one
PR. Every slice leaves an assignment with no groups on the code path it runs
today.

## Status

| slice | what | state |
|---|---|---|
| 0 | This design note | draft |
| 1 | Groups: group sets, groups, memberships; the Groups tab; the CSV import; the Group column on the roster; groups in the data export | built |
| 2 | Sessions: a session per (activity, group), started and ended from the present page; the submission gate reads the session; attendance by join code at `/join`; presence: a code for every student that changes every 30 seconds, the staff list of who joined, a limit on wrong codes, the "Other network" flag | built |
| 3a | Rankings per group, the leaderboard: `group_leaderboard_entries`, a late result does not rank, the board and the present page per group; other kinds refuse the flag until their slice | built |
| 3b | Rankings per group, the hill: `group_activity_champions`, a challenger plays their group's champion, the page and the present page show the group's hill | built |
| 3c | Rankings per group, the round robin: classmates are the students in the challenger's session, `activity_standings.group_id`, standings per group on the page and the present page | built |
| 3d | Rankings per group, the tournament: `tournament_runs.group_id`, a group's run is entered by its session, labs play at once, the bracket per group, the run control takes the group | built |
| 4 | The composite per group, and the course gallery of every group's image | not started |
| 5 | Group goals: the union and the corpus percent per group; a group achievement | not started |
| 6 | The LEARN source: the existing group-category sweep writes the new tables; a D2L Sections reader; the category picker | not started |
| later | Per-group deadlines; a TA's roster filtered to their groups; a `team` kind with a shared submission | not planned |

## The problem

A course runs its labs in nine sections. Each section meets at a different
time, in its own room, with its own TA. Every class activity today is
course-wide:

- The live-session window (`activity.window`) is one pair of instants on the
  assignment. Nine labs cannot each have their fifty minutes.
- The leaderboard, the standings and the hill rank the whole course. A
  student in the Tuesday lab competes against people who played on Thursday.
- A round robin plays every classmate in the course. For 225 students that is
  224 matches per submission. In a lab of 25 it is 24.
- A tournament snapshots the whole course's entrants. A bracket of 225 does
  not fit a lab. A bracket of 25 is five rounds.
- The composite deals slots across the course. The first lab fills the first
  48 slots and the second lab starts a second round on the same image. Each
  lab should make its own image.
- A class goal counts the course roster. "Your lab found all 15 bugs" is a
  better goal in the room than "the course found 12 of 15".
- The present page is one board for one course. A TA cannot project "Lab 103".

LEARN knows the lab sections. Reading them is useful but not sufficient: the
Valence grade sync still waits for UW IST production credentials (root
`CLAUDE.md`, "Current State"), LTI sends no groups, and a student who comes to
the wrong lab this week still has to play in the room they are in. So the room
itself must be able to make and fill a group.

## What exists today

| Piece | Where | What it does |
|---|---|---|
| The activity block | `TestProperties.activity` (`Sources/Core/ClassActivity.swift`) | `kind`, `leaderboardVisibility`, `opponentFile`, `window`, `composite`. All course-wide. |
| The window gate | `requireOpenStudentAssignment(gate: .submission)` | Refuses a submission outside `activity.window`. Staff are never gated. |
| The ranking rows | `leaderboard_entries`, `activity_standings`, `activity_champions`, `match_results`, `tournament_runs`, `composite_slots` | Keyed by assignment and student. Unique on (assignment, student); the hill is unique on the assignment alone. |
| The opponents | `WorkerJobRoutes.jobOpponentSet` / `jobOpponents` | Every classmate's latest submission in the course. |
| The present page | `GET /testsetups/:id/leaderboard?present=1`, `LeaderboardPresentPage` | One board per assignment, polled by the projector. |
| The arena | `WebRoutes+TournamentArena.swift` | Plays a browser-graded tournament in the presenter's browser. |
| A LEARN section sync | `LearnSectionSyncService`, `APICourse.brightspaceSectionCategoryID`, `APICourseEnrollment.brightspaceSection` | Writes a free-text group name per enrollment every ten minutes. No form sets the category, no page reads the name, no test covers it. |

The ranking rows are all materialised at ingest (`recordLeaderboardEntry`,
`recordClassItemCoverage` and their siblings, wired at both ingest paths). That
is the pattern this design extends: a row learns its group when it is written.

## The model

Three concepts.

- **Group.** A named set of students in a course, inside a **group set** that
  mirrors a LEARN group category ("Lab sections"). A student is in at most one
  group per set. A TA can be a member too; that is how the present page knows
  which group is theirs.
- **Session.** One group running one activity: a row per (assignment, group)
  with `opened_at`, `closed_at`, `opened_by` and a short **join code**. The
  session is the clock. The TA starts it from the present page when the room
  is ready and ends it when the lab ends. It can be reopened.
- **Participant.** A student who played in a session: a member of the group,
  or anyone who entered the session's join code. A participant's results are
  attributed to that session's group, whatever group LEARN says they are in.

The activity block gains one field, `runsPerGroup` (nil = false = today's
behaviour on every branch). When it is true for an assignment:

- A student submits only while their session is open. Their session is the
  open session they joined by code, else the open session of their group.
- Every ranking row written at ingest carries the student's `group_id`.
- Every board, bracket, hill, matrix and composite is read per group.
- The present page takes a group and shows that group's board, clock and join
  code.

When it is false, nothing reads a group, and the manifest window stays the
clock, as today.

```text
course_group_sets
  id, course_id, name, source (manual | learnGroups | learnSections),
  external_id, created_at, last_synced_at

course_groups
  id, set_id, name, external_id, sort_order, removed_at
  UNIQUE(set_id, external_id) where external_id is not null

course_group_memberships
  id, set_id, group_id, user_id, created_at
  UNIQUE(set_id, user_id)

activity_sessions
  id, assignment_id, group_id, code_secret, opened_at, closed_at, opened_by
  UNIQUE(assignment_id, group_id)

activity_session_attendance
  id, session_id, user_id, joined_at, removed_at, placed_in_group
  UNIQUE(session_id, user_id)
```

And, per ranking table, a per-group form: slice 3a made the leaderboard's a
twin table, `group_leaderboard_entries` keyed (assignment, group, student),
because a column under the existing (assignment, student) key strands a
student who moves labs. Slice 3b made the hill's a twin table too,
`group_activity_champions` keyed (assignment, group). Slice 3c gave
`activity_standings` a nullable `group_id` under its (assignment, student)
key: a standings row is the student's latest submission, never a best, so a
student who moves labs moves with it. Slice 3d gave `tournament_runs` a
nullable `group_id`: a run is one lab's, and its slots and matches follow
the run. The rest are still a nullable `group_id` in this plan:
`composite_slots`,
`composite_contributions`, `class_item_coverage`, `class_coverage_runs`.
Nil means course-wide, which is what every existing row is.

## Decisions

1. **The word is "group".** LEARN calls them groups. "Section" is taken twice
   in Chickadee (a course section groups assignments, a suite section groups
   tests) and "cohort" names the dataset seed. A page may say "lab group".
2. **The session is a row, not a manifest field.** The manifest's
   `activity.window` is authored content: two ISO strings set before the day.
   A session is operational: a TA presses Start at 14:05 because the room is
   ready. Content is versioned, exported in a course bundle and authored by
   MCP. A session is none of those. Keeping them apart is the same reason the
   window is not the deadline (docs/class-activities.md, slice 8).
3. **Membership decides the room; attendance decides who plays.** A member
   of a group joins only that group's session (maintainer decision 4); a TA
   moves a student who goes to another lab on the Groups tab. A student with
   no group who joins a session becomes a member of that group: the manual
   source that needs no form. Since Presence, only attendance counts: a
   member who has not typed the code does not play.
4. **The group is written at ingest and never recomputed.** A ranking row
   carries the group it was played in. A student who moves groups later keeps
   their place in the room they played in. This is the house pattern (every
   accumulator is materialised at ingest, docs/class-activities.md decision
   7), and it is why the ranking pages need no join on memberships.
5. **No unique key changes.** `activity_champions` is unique on the
   assignment alone. One hill per group needs (assignment, group), so slice
   3b added a twin table, `group_activity_champions`, rather than changing
   that key: a nullable group under a unique key admits two course-wide
   rows on Postgres, and the migration stays additive.
6. **Opponents come from the group.** A round robin plays the group's
   classmates. The hill's champion is the group's champion. A tournament's
   entrants are the group's participants. The bundled bot still stands in
   when a group has nobody yet.
7. **Each group makes its own composite.** Slots are dealt per (assignment,
   group, round, slot). A 6 × 8 starter grid suits a lab of 25 with spares
   for the fast students. The course page gains a gallery of every group's
   image, which is the end-of-term artefact.
8. **A group goal is the same goal, counted per group.** The union and the
   corpus percent read their rows filtered by group; breadth is the fraction
   of the group's current members. The achievement is awarded to the group's
   participants. The sweep stays blob-free and reconciles per group.
9. **Staff are never gated and may run any group's session.** A TA assigned
   to a group gets that group's present page by default. Any staff member can
   open any group's board, because the instructor walks between rooms.
10. **Each group set has one source, and a synced set is read-only in the
    UI.** `manual`, `learnGroups` (a D2L group category) or `learnSections`
    (D2L Sections). The join code adds members to a manual set only; on a
    synced set it records attendance and leaves membership to LEARN.
11. **Groups never cross the MCP wall.** Membership and attendance are
    student data. No MCP tool reads or writes a set, a group, a session or an
    attendance row (`Sources/APIServer/MCP/CLAUDE.md`). `set_activity` may
    set `runsPerGroup`, because that is content. Add the five tables to the
    "never touches" list in `docs/compliance/data-flow-inventory.md`.
12. **Grades do not change.** A submission's grade, its LEARN push and the
    assignment's deadline read nothing here. Only ranking, aggregation and the
    live clock become per group.

## What changes on each surface

| Surface | Today | With `runsPerGroup` |
|---|---|---|
| Submission gate | `activity.window` | The open session the student joined by code. No join: refused, with the join prompt. |
| Leaderboard | One board, course-wide | One board per group. `?group=` on the page; a student lands on their own. |
| King of the hill | One champion per assignment | One champion per group; the job stages the group's champion. |
| Round robin | Every classmate in the course | Every participant in the group. |
| Tournament | One run per assignment, started from the present page | One run per (assignment, group), started from the group's present page. The arena plays that group's bracket. |
| Composite | One image, slots dealt course-wide | One image per group; a gallery on the course page. |
| Class goal | The course roster | The group's members; the award goes to the group's participants. |
| Present page | One board | A group picker for staff; the TA's own group by default; the join code and the session clock on the board. |
| Students with no group | n/a | See the join prompt and the code's entry field on the assignment page. |

## Where the groups come from

| Source | When it fills a group | State |
|---|---|---|
| The join code on the projector | During the session, by the students in the room | Slice 2. Needs nothing outside Chickadee. |
| A CSV of `username,group` | Before the term, by the instructor; also the LEARN Groups export (group name, username, org-defined ID) | Slice 1. |
| The Groups tab | Any time, by an instructor | Slice 1. |
| A D2L group category through Valence | Every ten minutes | The reader exists (`fetchGroups`). Blocked on production credentials. Slice 6. |
| D2L Sections through Valence | Every ten minutes | **The UW source**: the registrar assigns the labs and LEARN makes a Section per lab. No reader yet. Verify the route and the member field against the Valence reference first; the public search did not reach the page. Slice 6. |
| LTI 1.3 | never | NRPS sends no group per member. D2L lists AGS, NRPS and Deep Linking as its LTI Advantage services, not the Course Groups Service. |

The existing reader handles group categories only, so slice 6 starts with
the Sections reader.

## Slices

### Slice 1: groups (built)

- One migration, `CreateCourseGroups`, makes the three tables. A membership
  carries its set as well as its group, so the unique key (set, user) keeps a
  person in at most one group of a set in the database itself, not only in the
  app.
- `CourseGroupStore` holds every read and write: the sets of a course, the
  groups of a set, each member's group, `setMembership` (one move),
  `replaceMemberships` (the import, and the sweep in slice 6), `removeGroup`
  and `importRoster`. A write to a synced set is refused
  (`CourseGroupError.setNotEditable`). A removed group keeps its row and loses
  its members. A membership of a student who later leaves the course stays,
  and every count reads enrolled students only.
- `GroupRosterCSV` reads two shapes: `username,group` with no header, or a
  header that names a username column and a group column among others (the
  LEARN Groups export). A student in two groups refuses the whole file. The
  import replaces every membership of the set, makes the groups the file
  names, and lists the usernames that match no student of the course.
- The instructor **Groups** tab (`/instructor/groups`): make the set, add or
  remove a group, import a file. Course staff read it. Every write is floored
  at `.instructor` on the set's own course, and refused in an archived course.
  No group route takes a path parameter, so `RouteAuthorizationMatrixTests`
  does not walk them; `GroupsRoutesTests` is their authorization check.
- The Students tab gets a sortable Group column when the course has a set: a
  select per student for an instructor, the group's name for a TA. The Filter
  box matches it.
- Each change is audited as `enrollment.groups_changed` and shows on the
  course's Activity tab.
- A student's personal data export lists their group in each set.
- Tests: `GroupRosterCSVTests`, `CourseGroupStoreTests`, `GroupsRoutesTests`,
  and the page fixtures in `ElementaryPageFixtures+Groups.swift`.

### Slice 2: sessions (built)

- `ClassActivity.runsPerGroup` (Core). It is encoded only when true, so a
  block that does not run per group keeps its bytes, and every `with…`
  rebuild keeps it. `withRunsPerGroup` sets it.
- `ActivityAuthoring` refuses it in a course with no group set, beside a
  session window (each group's session replaces the window as the clock), and
  on a class composite (slice 4). It reads the group sets on the owner pool,
  since the least-privilege MCP role cannot.
- The edit page's session form gains a "Run once per lab group" checkbox
  (`POST /instructor/:assignmentID/activity/window`, unchanged floor). The
  form sends the whole session state, so an unticked box turns the flag off.
  `set_activity` takes and reports `runsPerGroup`, keeping the stored value
  when the field is absent, and `get_assignment` reports it.
- `CreateActivitySessions` makes `activity_sessions` (unique on assignment and
  group, with a code secret) and `activity_session_attendance` (unique on
  session and student, with `removed_at`). `ActivitySessionStore` starts, ends
  and reopens a session, joins by code, and answers which session a student
  plays in now: the open session they most recently joined by code, or none.
  Membership alone is not enough (see "Presence" below). A join from before
  the session's latest start does not count. Start on an open session changes
  nothing. A reopen keeps the row and draws a new code secret. Sessions use
  the course's first group set, which in slice 2 is its only one; a start
  that names a group of another set is a 404.
- Joining records attendance, or moves its time to now on a join that moves
  the student from another session. Typing the code of the session the
  student already plays in changes nothing, so a submission made before it
  still ranks when it is graded.
  A student in no group of a manual set becomes a member of the session's
  group; a member of another group is refused ("This session is for Lab 103.
  You are in Lab 101.", maintainer decision 4). A removed group's session, and a session of an
  activity that no longer runs per group, or of an archived course, refuse a
  join (an ended session shows no code to type). Removing a group ends its
  open sessions, and so does turning
  `runsPerGroup` off (the edit page, `set_activity` or a version restore), so
  turning it on again never brings back an earlier lab's code.
- A clone and a bundle import clear `runsPerGroup`, because neither copies
  group sets: with no group there is no session, and every student would be
  refused while staff see nothing wrong (the #2189 trap).
- `requireOpenStudentAssignment(gate: .submission)` reads the student's
  session when the activity runs per group. The refusal
  (`AssignmentSubmissionGateError.notInGroupSession`) sends the student to
  `/join`. Staff are never gated, and reading is not gated. Until slice 3, a closed session refuses a
  submission, as a closed window does. Decision 1 lets a submission after the
  close grade without ranking, and that needs the ingest check of slice 3, so
  slice 3 relaxes the gate when it adds the check. The gate covers the web
  submission doors. The JSON
  door, `POST /api/v1/submissions`, checks enrollment only, so it skips the
  session gate and the window gate today. That gap is older than groups and
  is not closed here.
- The present page gains `PresentSessionControls` (the group select, Start,
  End or Reopen, and "Who joined", in the presenter's corner) and, while the
  session is open, `PresentJoinCode` above the board: the address, the code,
  the seconds until it changes and how many joined. The join box is its own
  polled region (`?fragment=join`, every two seconds), outside the board's.
  The controls are in the presenter's toolbar, which full screen hides, so
  the presenter leaves full screen to end the session; the code stays on the
  wall in full screen.
  `POST /testsetups/:testSetupID/sessions/start`, `/end` and `/remove` are
  floored at `.ta` on the activity's course, in a course that is not
  archived; `GET .../sessions/attendance` is floored at `.ta` and reads an
  archived course too. The caller is authorized before the activity is read.
  Each start, end and removal is audited as `activity_group_session.changed`
  and shows on the course's Activity tab.
- `GET /join` and `POST /join` (`JoinSessionPage`) take a code and send the
  student to the assignment's vanity path.
- A student's personal data export lists the sessions they joined.
- Tests: `ClassActivityRunsPerGroupTests`, `ActivitySessionCodeTests`,
  `ActivitySessionStoreTests`, `GroupSessionGateTests`,
  `GroupSessionRoutesTests`, and the fixtures in
  `ElementaryPageFixtures+Sessions.swift`.

### Presence (built, in slice 2)

The goal is best effort, not proof: a student who is not in the room should
need a friend in the room who relays each code as it changes, and staff
should be able to see it. The maintainer chose best effort on 2026-10-18.

- **Every student types the code.** Membership decides which group a student
  in no group joins. It does not let a student submit. A member of the
  session's own group joins too.
- **The code changes every 30 seconds** (`ActivitySessionCode`), so a code
  works for 30 to 60 seconds. The session
  keeps a random secret, and the code for a 30-second step is an HMAC of the
  step under it, so nothing is written when the code changes. A join takes
  the current code and the one before it, so a student who is typing when it
  changes is not refused. `/join` matches the code against every open
  session; two open sessions showing one code at once is a chance of a few
  in ten million, and the student then types the next code.
- **Staff see who joined.** "Who joined" on the present page opens
  `SessionAttendancePage` in a new tab, because it shows names and the
  present page is on the projector. The projector shows only the count. A
  presenter whose screen is mirrored to the projector opens it on another
  device.
  Remove asks first, then takes a student out of the current run: they stop
  playing and cannot join again until the session starts again. If their
  join had placed them in the group (they were in no group of a manual set),
  Remove takes them out of the group too. A join that races a Remove does
  not undo it. A student's data export lists a removal with its time.
- **Wrong codes are limited.** About ten wrong codes in ten minutes stop a
  student's joins until the oldest leaves the window (the check and the
  write are separate, so a burst of parallel requests can pass a few more).
  The failures are rows in `login_attempts` (scope `join_failure`, keyed by
  user id), which the login attempt sweep removes after an hour.
- **The network flag.** Every student is on eduroam, so the network part
  of the address is a signal. Chickadee stores the network part only
  (`ClientNetwork.prefix`: a /24 for IPv4, a /64 for IPv6), never the full
  address: the presenter's on Start and on each refresh of the join box
  (`presenter_network`, only for the staff member who started the session),
  and each student's on each join (`join_network`). The address is the last
  `X-Forwarded-For` entry, the one the deployment's nginx appends, because
  the first entry is the client's to choose. The room's networks are the
  presenter's, the one that most joins came from, and any that at least a
  fifth of the joins came from (`SessionNetworkCheck`). So a TA on a wired
  lab network does not flag a room on eduroam, and on dual-stack Wi-Fi the
  IPv4 and IPv6 halves of one room are both the room. "Who joined" marks a join from any other network
  "Other network" for staff to check. It is a flag, never a refusal: campus
  Wi-Fi may share one pool across buildings, and the university VPN gives a
  campus address off campus, so a wrong refusal would lock out an honest
  student. An unknown network is never flagged. The student's data export
  lists the network of each join. To be decided after the first labs:
  whether one lab's joins share a network every time, which would make an
  optional refusal per course safe.

### Slice 3a: the leaderboard per group (built)

- `group_leaderboard_entries` (`CreateGroupLeaderboardEntries`): one best
  row per (assignment, group, student), the per-group twin of
  `leaderboard_entries`. A second table, not a column, so a student who
  plays in two labs ranks in each, and a course-wide row from before the
  activity ran per group blocks nothing. `recordLeaderboardEntry` writes a
  per-group activity's result under the group of the session the student
  had joined when they submitted (`ActivitySessionStore.sessionAtSubmission`:
  by the submission's own time, and only a join made before it, so a
  grading delay costs no student their place). A submission made with no
  such session open grades and does not rank (decision 1). A retest after
  the session restarted finds no session and leaves the board as it was.
  The `highestMetric` class record stays course-wide.
- `buildLeaderboard` takes a group. `LeaderboardGroupScope` picks it: staff
  choose with `LeaderboardGroupControl` (`LabGroupSelect`, `?group=`,
  landing on their own group); a student reads the group whose session they
  last joined, else one they ranked in, else the one they are a member of,
  and a student's `?group=` is ignored. A student in no group has no board
  and a note that sends them to `/join`. The page refreshes while the shown group's session
  is open. The staff "not ranked" count is the group's members.
- The present page projects the selected group's board, and its refresh
  and the leaderboard's Present link keep the group.
- `ActivityKind.canRunPerGroup` (Core) is the one rule: a leaderboard kind
  (Best metric, Beat the instructor, and since slice 3b Beat the champion),
  and since slice 3c the Round robin.
  `ActivityAuthoring` refuses the flag on every other kind
  (`runsPerGroupKindMessage`), the edit page shows the checkbox only for
  these kinds, `set_activity` keeps a stored flag only for them.
  `ClassActivity.isPerGroup` (the flag and the
  kind rule) is what every reader reads: the gate, the session routes, the
  present panel, the board and ingest. So an older per-group activity of
  another kind reads as course-wide everywhere at once, and its students
  are not asked for a code that ranks nowhere. The union
  would mix the groups until their slices make them per group. A composite
  keeps its own message.
- The submission gate refuses only a student who never joined one of the
  activity's sessions, or whom staff removed (`ActivitySessionStore.hasJoined`).
  After the session a student joined closes, their submission grades and
  does not rank (decision 1). A member of a group who missed their lab stays
  refused.
- The staff board's submission count stays the student's total for the
  activity, not per group (maintainer decision 6).
- Tests: `LeaderboardPerGroupTests`.

### Slice 3b: the hill per group (built)

- `group_activity_champions` (`CreateGroupActivityChampions`): one row per
  (assignment, group), the per-group twin of `activity_champions`. `Hill`
  (`Services/Hill.swift`) names the hill a match plays for: the
  assignment's, or the group of the session the student had joined when
  they submitted (`Hill.of`, through `sessionAtSubmission`). The rules of
  the hill are unchanged and live once, in `recordActivityMatch`; only the
  row that holds the hill differs (`HillHolder`).
- At claim, `chooseOpponent` stages the champion of the student's group. A
  submission made with no session open plays the bot, or nobody, and its
  result moves no hill (decision 1). The result path resolves the same hill
  from the same submission, so the champion check reads the row the claim
  read.
- The champion class record is not awarded for a per-group hill: a record
  has one holder, and the activity has a hill in every lab. So the
  authoring door seeds no champion record on a per-group hill, and removes
  a seeded one when the flag goes on (an instructor-authored one stays). The
  `highestMetric` record stays course-wide, as in slice 3a.
- Remove on "Who joined" forgets the removed student's rankings in that
  group: the hill when they hold it, and (with slice 3c) their group
  leaderboard row and their standing. So no challenger plays a student who
  was not in the room, and no board shows them. A result that lands after
  its student was removed finds no session and moves no hill.
- The two hill tables are independent. Turning the flag on leaves the
  course-wide champion in place, and turning it off leaves each group's;
  the hill that `Hill.of` picks is the only one read, and turning the flag
  back brings the earlier hill back.
- The leaderboard page and the present page show the champion of the group
  they show (`buildChampionPresentation(groupID:)`); a student in no group
  sees no hill. The metric board under the hill is the slice 3a board.
- `ActivityKind.canRunPerGroup` is now every leaderboard kind: Best metric,
  Beat the instructor and Beat the champion.
- Tests: `HillPerGroupTests`.

### Slice 3c: the round robin per group (built)

- `chooseClassmates` plays the students in the session the challenger
  submitted in: that run's attendance, removed students left out, each
  with their latest complete submission. A submission made with no session
  open plays only the bot, or nobody.
- `activity_standings.group_id` (`AddActivityStandingGroup`): the group of
  the session the row's submission was made in. A standings row stays the
  student's latest submission, so it moves with a student who plays in
  another lab. A result that lands with no session open grades and leaves
  the student's standing as it was.
- `rankedStandings` and `buildStandingsBoard` take a group; the leaderboard
  page and the present page show the group they show, and a student in no
  group sees no standings. A student's `standing` badge signal is their
  place on the board the page shows: in the group of their own row while
  the activity runs per group, among the class rows otherwise.
- The standings-leader class record is not awarded for a per-group round
  robin, as with the hill (slice 3b): every lab has a leader. So
  `setActivity` seeds none on a per-group round robin, and removes a seeded
  one when the flag goes on.
- Known limits, accepted: an opponent's latest submission may have been
  made in another lab or after a session, because "latest" is the one
  definition the union and the tournaments share. A standings row written
  before the activity ran per group has no group: it is in no lab's
  standings, and that student's `standing` signal ranks them among the
  other rows with no group until they play in a session. Turning the flag
  off leaves each row's group on it, and the class standings read only rows
  with no group, so a lab's row leaves the class board, the badge signal
  and the standings-leader record until that student submits again.
- A retest of a standing's own submission that finds no session (after a
  reopen, or after a Remove) deletes that standing: the retest voided the
  matches it counted.
- Tests changed with the maintainer's direction (each activity can be
  scoped to the whole class or a lab): the round robin joins the kinds that
  can run per group in `ClassActivityIsPerGroupTests` and leaves the refused
  kinds in `LeaderboardPerGroupTests`. New: `RoundRobinPerGroupTests`.

### Slice 3d: the tournament per group (built)

- `tournament_runs.group_id` (`AddTournamentRunGroup`). For an activity
  that runs per group, `startTournament` takes a group: its entrants are the
  students who joined the group's session (the latest run, removed students
  left out), each with their latest complete submission, seeded in
  submission order. It refuses with no group (`noGroupChosen`), a group
  that never started its session (`noSession`) and fewer than two entrants.
- A new run supersedes only its own group's run in progress, so two labs
  play at once. `latestTournament` takes a group; with none it reads only
  whole-class runs.
- Slots, matches, the claim and the result need no group: each resolves
  through the run.
- The projector arena plays the matches of every running run of the
  assignment, so any presenter's browser can play any lab's match; a match
  is decided by the code, not by the room.
- The leaderboard page and the present page show the bracket of the group
  they show; a student in no group sees none.
- The run control on the submissions page takes a lab group for a per-group
  activity. MCP `run_tournament` refuses one (decision 11: choosing a group
  is choosing students).
- A lab's winner holds no class record, as with the hill and the round
  robin, and `setActivity` seeds none on a per-group tournament.
- Every write that changes the scope (`setActivity`, the MCP version
  restore) supersedes the running runs of the other scope
  (`supersedeRunningTournaments`), so no run plays on where no page shows
  it. The present page projects no bracket for a per-group tournament with
  no group chosen.
- Known limits, accepted: a run's entrants are frozen at its start, so a
  student whom staff remove afterwards stays in that bracket. A tournament
  that carried `runsPerGroup` from before slice 3a, which read as
  course-wide until now, runs per group from this slice on.
- Changed under the maintainer's direction: the tournament joins the kinds
  that can run per group in `ClassActivityIsPerGroupTests`. New:
  `TournamentPerGroupTests`.

### Slice 4: the composite per group

- `group_id` on `composite_slots` and `composite_contributions`; the slot key
  becomes (assignment, group, round, slot). `CompositeSlots` deals within the
  student's session group.
- The composite view takes a group. The course page shows a gallery of every
  group's image once their sessions have closed.
- Tests: two groups dealt the same slot numbers, a student who joined another
  group's session dealt there, the gallery order.

### Slice 5: group goals

- `group_id` on `class_item_coverage` and `class_coverage_runs`. The sweep
  evaluates a class goal once per group when the assignment runs per group,
  and awards it to that group's participants.
- The corpus run becomes one `classAggregate` submission per group.
- Tests: coverage per group, breadth over the group's members, an award that
  reaches only the group.

### Slice 6: the LEARN source

- `LearnSectionSyncService` becomes `LearnGroupSyncService`, writes through
  `CourseGroupStore`, upserts by external ID, marks a vanished group removed,
  and stops writing `brightspaceSection`. A migration makes one `learnGroups`
  set from a non-null `brightspaceSectionCategoryID`.
- The BrightSpace tab gets the category and section picker and a "Sync now"
  button.
- `BrightSpaceAPIClient.fetchSections` first, after the route is verified:
  it is the source the UW labs come from.
- Tests with a fake `BrightSpaceGrading`: a first sync, a rename, a member who
  moves, a group that disappears, a student the classlist cannot match. Today
  the sweep has no tests at all.

## Deferred: what the same model can carry later

These were the first draft of this note. They are not the goal, and none of
them is needed for a session in a room. They are listed so the model is not
redesigned when one of them is wanted.

- **Per-group deadlines.** A table of (assignment, group, opens_at, due_at)
  folded into `effectiveDueAt`. The blast radius is every student-facing read
  of `assignment.dueAt` (29 files today), and the post-deadline reveal would
  need a rule for which group's deadline it waits for.
- **A TA's roster filtered to their groups.** Soft: a default filter on the
  Students tab and the submissions list. The per-course gates do not change.
- **A `team` kind with a shared submission.** A set of kind `team` and a
  submission that belongs to a group. The hook is `APISubmission` ownership.
  The in-lab version is pairs formed in the room by a second join code, and
  it is a separate design.

## Decisions from the maintainer (2026-10-18)

The three questions the first draft left open are settled.

1. **The board freezes when the session closes.** A session is time-limited
   to the lab's own slot. A submission after the close still grades, because
   the assignment is still open, but it does not rank, move the hill, enter
   a bracket or take a slot. The ingest writers check the session before
   they write a ranking row. This is the one place a session changes what a
   result does, and it is deliberate.
2. **The lab groups are registrar-assigned and arrive in LEARN as D2L
   Sections.** So the LEARN source is Sections, not a group category, and
   slice 6 needs `fetchSections` before it is useful. The existing
   group-category reader stays for a course that makes its own groups in
   LEARN. The route and the member field are still to be verified against the
   Valence reference.
3. **A student in no group, with no code, cannot submit** when the activity
   runs per group. The refusal shows the join prompt. An unattributed result
   would rank nowhere, and the room is where the activity happens. Presence
   (2026-10-18) widens this: no student submits without the code, a member
   of the group included.
4. **A member joins only their own group's session** (later on 2026-10-18).
   The registrar assigns the labs, so membership is reliable, and a door
   into every lab weakens presence. A student in no group may still join
   any session. A student who goes to another lab is moved by a TA on the
   Groups tab (a synced set cannot be edited, so that case waits for a
   "let in" action or slice 6). A student moved to another lab cannot type
   the old lab's code again. A student in no group whose first join was in
   the wrong lab is a member of that lab now: a TA presses Remove on that
   session, which undoes the placement, or moves them on the Groups tab.
5. **A student who joined still submits after the close.** The result
   grades and does not rank, as decision 1 says. Only a student who never
   joined, or whom staff removed, is refused.
6. **The staff submission count is the student's total** for the activity,
   not per group. Only a student who played in two labs shows a
   difference, and a per-group count needs the session of each submission.

One consequence of decision 1 to carry into slice 2: because each session is
the lab's assigned slot, a session may later take a planned open and close
from the timetable, so a TA does not have to press Start. The row already has
the two instants; a planned session is one that is written before the day.
The TA's Start and End still win.

## Sources

- 1EdTech, Course Groups Service glossary entry:
  <https://learn.1edtech.org/mod/glossary/showentry.php?eid=154>
- D2L, LTI Advantage v1.3 knowledge-base article (the services D2L lists):
  <https://community.d2l.com/brightspace/kb/articles/23660-lti-advantage-v1-3>
- D2L, creating and updating sections through the API:
  <https://community.d2l.com/brightspace/kb/articles/1171-creating-updating-sections>
- D2L Valence, groups reference:
  <https://docs.valence.desire2learn.com/res/groups.html>
- Minnesota State, what the Groups tool export contains:
  <https://servicedesk.minnstate.edu/TDClient/30/Portal/KB/PrintArticle?ID=411>
