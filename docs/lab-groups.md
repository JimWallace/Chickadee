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
| 1 | Groups: group sets, groups, memberships; the Groups tab; the join code; the CSV import; the Group column on the roster | not started |
| 2 | Sessions: a session per (activity, group), started and ended from the present page; the submission gate reads the session; attendance by join code | not started |
| 3 | Rankings per group: leaderboard, standings, the hill, round-robin opponents, tournament runs, the present page per group | not started |
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
  id, group_id, user_id, created_at
  UNIQUE(group_id, user_id)

activity_sessions
  id, assignment_id, group_id, join_code, opened_at, closed_at, opened_by
  UNIQUE(assignment_id, group_id); UNIQUE(join_code) while open

activity_session_attendance
  id, session_id, user_id, joined_at
  UNIQUE(session_id, user_id)
```

And one nullable `group_id` column on each ranking table:
`leaderboard_entries`, `activity_standings`, `activity_champions`,
`match_results`, `tournament_runs`, `composite_slots`,
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
3. **Attendance beats membership.** A student who enters Lab 103's code plays
   in Lab 103, even if LEARN puts them in Lab 101. The join code is the one
   thing a TA can control from the front of the room. It also fills a group
   with no source at all: a student with no group who joins a session becomes a
   member of that group. That is the manual source that needs no form.
4. **The group is written at ingest and never recomputed.** A ranking row
   carries the group it was played in. A student who moves groups later keeps
   their place in the room they played in. This is the house pattern (every
   accumulator is materialised at ingest, docs/class-activities.md decision
   7), and it is why the ranking pages need no join on memberships.
5. **One unique key changes.** `activity_champions` is unique on the
   assignment alone today. One hill per group needs (assignment, group). That
   is the one non-additive migration in the plan, and the reason the hill is
   in slice 3 rather than a later one: the rest of the ranking tables keep
   their (assignment, student) keys, since a student has one group per set.
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
| Submission gate | `activity.window` | The student's open session. No session: refused as `.activityNotYetOpen`, with the group's name. |
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
| The join code on the projector | During the session, by the students in the room | Slice 1 and 2. Needs nothing outside Chickadee. |
| A CSV of `username,group` | Before the term, by the instructor; also the LEARN Groups export (group name, username, org-defined ID) | Slice 1. |
| The Groups tab | Any time, by an instructor | Slice 1. |
| A D2L group category through Valence | Every ten minutes | The reader exists (`fetchGroups`). Blocked on production credentials. Slice 6. |
| D2L Sections through Valence | Every ten minutes | **The UW source**: the registrar assigns the labs and LEARN makes a Section per lab. No reader yet. Verify the route and the member field against the Valence reference first; the public search did not reach the page. Slice 6. |
| LTI 1.3 | never | NRPS sends no group per member. D2L lists AGS, NRPS and Deep Linking as its LTI Advantage services, not the Course Groups Service. |

The existing reader handles group categories only, so slice 6 starts with
the Sections reader.

## Slices

### Slice 1: groups

- The three group tables and `CourseGroupStore`: the sets of a course, the
  groups of a set, a student's group in a set, a group's members, and
  `replaceMemberships(set:assignments:)`, which the Groups tab, the CSV import
  and the sweep all call.
- The instructor **Groups** tab, per-course `instructor` only. Create a set,
  add a group, move a student with a select on the roster row, import a CSV.
  A TA reads it.
- The Students tab gets a Group column and the Filter box matches on it.
- Tests: the one-group-per-set rule, a replace that moves a student, a removed
  group keeps its rows, the two CSV shapes, a student in two groups in one
  file is refused.

### Slice 2: sessions

- `runsPerGroup` on the activity block, with `withRunsPerGroup` rebuilding the
  block as the three existing edit forms do (docs/class-activities.md,
  "Compatibility rules"). The edit page and `set_activity` set it. It is
  refused when the course has no group set.
- `activity_sessions` and `activity_session_attendance`, and
  `ActivitySessionStore`: open, close, reopen, join by code, the session for a
  student now, and whether a session is open at an instant (the ingest
  writers ask this in slice 3 before they write a ranking row).
- The present page gains Start, End and the join code. The code is five
  characters from an alphabet with no look-alike glyphs, and it is shown large.
- The assignment page shows a student the join field when their activity runs
  per group and they are in no open session.
- `requireOpenStudentAssignment(gate: .submission)` reads the session when
  `runsPerGroup` is set, else the manifest window as today. The refusal names
  the group.
- Tests: the gate table (member of an open session, member of a closed one,
  joined by code into another group's session, no group and no code, staff),
  the code's uniqueness while open, a reopen.

### Slice 3: rankings per group

- `group_id` on `leaderboard_entries`, `activity_standings`,
  `activity_champions`, `match_results` and `tournament_runs`. The ingest
  writers resolve the student's session group once and stamp it.
- The hill's unique key becomes (assignment, group). `jobOpponent` stages the
  group's champion. `jobOpponentSet` lists the group's participants.
- The leaderboard, standings and bracket pages filter by group. The present
  page takes a group; a TA with a group membership lands on it.
- "Run tournament" and the arena routes take the group. `run_tournament` on
  MCP refuses a `runsPerGroup` assignment, because choosing a group is choosing
  students.
- A result that lands after the group's session closed grades and does not
  rank (maintainer decision 1).
- Tests: an entry stamped with the right group, the hill per group, a round
  robin that plays only the group, two groups' tournaments running at once,
  a late result that grades but leaves the board as it was.

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
   would rank nowhere, and the room is where the activity happens.

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
