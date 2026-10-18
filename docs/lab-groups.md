# Lab Groups

Design note for student groups inside a course: lab groups of about 25
students, the staff who run them, and the things that differ per group. The
first use is lab sections that meet on different days. The model is written so
that project teams can use it later without a second model.

Read **What exists today** and **Decisions** before you touch code. Each slice
is one PR. Every slice leaves a course with no groups on the code path it runs
today.

## Status

| slice | what | state |
|---|---|---|
| 0 | This design note | draft |
| 1 | The model and the manual source: group sets, groups, memberships, the Groups tab, CSV import, the roster column and filter, the export column | not started |
| 2 | The LEARN source: the existing group-category sweep writes the new tables, the category picker on the BrightSpace tab, a D2L Sections reader, tests with a fake client | not started |
| 3 | Per-group schedules: a due date and an open date per group, one deadline resolver for every student-facing read, the reveal rule | not started |
| 4 | Staff in groups: a TA assigned to groups, the Students tab and the submissions list filtered to their groups by default | not started |
| 5 | Later: a group as the scope of a class activity or a composite; a `team` kind with a shared submission | not planned |

## The problem

A large course runs its labs in sections of about 25 students. Each section
has a day, a room and a TA. Today Chickadee knows none of this:

- The roster is one flat list. A TA who runs Lab 103 scrolls past the other
  eight sections to find their students.
- An assignment has one due date for the whole course. A lab that meets on
  Tuesday and a lab that meets on Thursday cannot have different deadlines.
  The only tool is the per-student extension (`APIAssignmentExtension`), one
  row per student, granted by hand.
- The grades CSV carries a `learnSection` column, but nothing writes it in
  production (see below), so it is always empty.
- Issue #544 asked for a TA role "scoped to sections". The role shipped
  (`CourseRole.ta`, docs/multi-course-roles.md). The scoping half did not.

LEARN already holds the lab groups. The ideal is to read them from there. The
sources are mixed, so the model must not depend on any one of them.

## What exists today

A backend for one source shipped in 0.4 (`CHANGELOG-0.4.md`, "LEARN section
sync (backend)") and its UI follow-up never landed:

| Piece | Where | State |
|---|---|---|
| The D2L group category to read | `APICourse.brightspaceSectionCategoryID` | A column. No form sets it. |
| The student's group name | `APICourseEnrollment.brightspaceSection` | A free-text string, for example "Lab 3". |
| The sweep | `LearnSectionSyncService.swift`, every 10 minutes | Runs only when a course has both the org unit and the category. |
| The D2L reads | `BrightSpaceAPIClient.fetchGroupCategories`, `fetchGroups` | Paged, with clock-skew retry. |
| Readers of the name | `DataExportContent` (`learnSection`) | The only reader. No page shows it. |
| Tests | none | No test references the sweep or the two fetchers. |

Two facts limit this backend:

- A string on the enrollment cannot carry anything else. A deadline, a TA
  assignment or a leaderboard cannot point at "Lab 3". A rename in LEARN
  silently makes a new group.
- The Valence grade sync still waits for UW IST production credentials (root
  `CLAUDE.md`, "Current State"). Until they arrive, nothing on the Valence path
  runs in production. A design that only works through Valence is a design
  that does not work this term.

## Where LEARN can supply groups

| Source | What it gives | State |
|---|---|---|
| D2L Groups (a group category) | Group names and the D2L user ID of each member, through `lp/(v)/(orgUnit)/groupcategories/(cat)/groups/` | Reader exists (`fetchGroups`). Blocked on production credentials. |
| D2L Sections | The registrar-fed sections of a course offering, each with a name and a member list, through `lp/(v)/(orgUnit)/sections/` | No reader. The same shape as a group. Verify the route and the `Enrollments` field against the Valence reference before slice 2; the public search did not reach the page. |
| LTI 1.3 NRPS | The membership of the context: subject, roles, status, student number (`LTIMember`) | No group or section per member. |
| LTI Course Groups Service | A 1EdTech extension that lists a context's groups and their members | D2L's LTI Advantage page lists AGS, NRPS and Deep Linking only. Treat as unsupported until D2L says otherwise. |
| A LEARN export file | The Groups tool exports group name, username and org-defined ID per member. The Grades export can be filtered to one section or group. | Always available to an instructor. Needs a parser. |

Before slice 2, check in the LEARN site whether the lab sections appear under
Course Admin as **Sections** or as a **Group category**. UW registrar feeds
usually make Sections. The existing reader only handles group categories.

So: a LEARN-bound course can sync through Valence once the credentials exist;
an LTI-bound course cannot read groups from the LMS at all; every course can
import a file. The model treats each as a *source* of one group set, and the
rest of Chickadee never asks which source a set came from.

## Decisions

1. **The word is "group".** LEARN calls them groups. "Section" is taken twice
   in Chickadee: a course section groups assignments, and a suite section
   groups tests. "Cohort" names the per-student dataset seed. A page may say
   "lab group" where the kind is known.
2. **A group set per course, mirroring a D2L group category.** A set has a
   name ("Lab sections"), a source, and the rule that a student is in at most
   one of its groups. A course may hold several sets later (lab sections and
   project teams). Slice 1 builds the tables for several and the UI for one.
3. **Tables, not the string column.** `course_group_sets`, `course_groups`
   and `course_group_memberships`. A deadline, a TA assignment and a
   leaderboard point at a group row with a stable ID. The existing string
   column becomes legacy: the sweep stops writing it, nothing reads it, and a
   later cleanup drops it (the `legacyAvatarHandle` pattern).
4. **Membership is one table for students and staff.** A row is
   (group, user). The user's role in the group is their enrollment role in the
   course. A TA in Lab 103 is a membership row for a user whose enrollment
   says `ta`. There is no second role system.
5. **Each set has one source, and a synced set is read-only in the UI.**
   `manual` (the Groups tab and a CSV import), `learnGroups` (a D2L group
   category) or `learnSections` (D2L Sections). An instructor who wants to
   hand-edit a synced set makes a manual copy. This avoids a merge rule
   between LEARN and local edits, which is where group sync tools go wrong.
6. **The sweep upserts by external ID.** A rename in LEARN renames the group.
   A group that leaves LEARN is kept and marked removed, so its schedule rows
   and history stay. Memberships are replaced per run. Students match through
   the existing `BrightSpaceIdentityIndex`, the same rule as the grade push.
7. **Per-group schedules are additive.** `assignment_group_schedules` carries
   an optional `opens_at` and an optional `due_at` per (assignment, group). A
   student's effective deadline is their group's `due_at` when one exists,
   else the assignment's `dueAt`, and the per-student extension folds on top
   through `laterDeadline` as today. An assignment with no schedule rows
   behaves exactly as today.
8. **The reveal waits for the last group.** Release-tier output and the
   solution reveal for a student gate on the latest `due_at` across the
   assignment's groups, not on the student's own. A Tuesday group that sees
   the solution while the Thursday group still works is a 25-student leak,
   not the one-student leak the extension already accepts. The slip-day
   ceiling and the per-student extension still fold on top of that moment.
   This is the one place where a group changes behaviour for a student who is
   not in it. **Maintainer decision needed.** The alternative is the student's
   own deadline, as extensions do today.
9. **Staff scoping is soft in slice 4.** A TA assigned to groups gets the
   Students tab and the submissions list filtered to those groups by default,
   with a control to show the whole course. The per-course gates
   (`requireCourseRole(atLeast:)`) do not change. Hard scoping, where a TA
   cannot open another group's submission, touches every staff read gate and
   breaks the small course where two TAs grade everything. Decide it after a
   term of use.
10. **Groups never cross the MCP wall.** Membership is enrollment data. No MCP
    tool reads or writes a set, a group or a membership
    (`Sources/APIServer/MCP/CLAUDE.md`). Group names and schedules are
    instructor lifecycle data, and the lifecycle tools stay off MCP as they are
    today. Add the three tables to the "never touches" list in
    `docs/compliance/data-flow-inventory.md`.
11. **A team with a shared submission is a different feature.** The model
    leaves room for it: a set of kind `team` and a submission that belongs to
    a group. The hook is `APISubmission` ownership, and nothing in slices 1 to
    4 touches it.

## Model

```text
course_group_sets
  id, course_id, name, kind (lab | team), source (manual | learnGroups | learnSections),
  external_id (the D2L category or null), created_at, last_synced_at

course_groups
  id, set_id, name, external_id (the D2L group or section id, or null),
  sort_order, removed_at (set when the source no longer lists it)
  UNIQUE(set_id, external_id) where external_id is not null

course_group_memberships
  id, group_id, user_id, created_at
  UNIQUE(group_id, user_id)
  (a student is in at most one group per set; the app enforces it, and the
  sweep replaces a student's row rather than adding one)

assignment_group_schedules   (slice 3)
  id, assignment_id, group_id, opens_at (nullable), due_at (nullable)
  UNIQUE(assignment_id, group_id)
```

Models follow the house rules: Fluent `Model` classes under
`Sources/APIServer/Models/`, `@unchecked Sendable` only there, raw columns read
through typed accessors, migrations folded into the create migrations as the
enrollment columns were. `APICourse` gains a `groupSets` children relation.
Deleting a course cascades through all four tables.

## Slice 1: the model and the manual source

- The tables above (without schedules), and `CourseGroupStore`, one place for
  the reads and writes: the sets of a course, the groups of a set, the group of
  a student in a set, the students of a group, and `replaceMemberships(set:
  assignments:)`, which both the Groups tab and the sweep call.
- An instructor **Groups** tab under `/instructor/groups`, per-course
  `instructor` only (membership is enrollment management, like the roster).
  Create a set, add a group, move a student between groups with a select on
  the roster row, and import a CSV of `username,group` (also the LEARN Groups
  export, whose columns are detected the way `parseUsernamesFromCSV` detects
  the gradebook export). A TA reads the tab and changes nothing.
- The Students tab gets a **Group** column and the Filter box matches on it.
  `EnrolledStudentRow` gains `groupName`.
- The student's course page shows their group under the course title.
- The grades CSV column `learnSection` becomes `group`, filled from the
  membership rather than the legacy string.
- Tests: `CourseGroupStoreTests` (the one-group-per-set rule, a replace that
  moves a student, a removed group keeps its rows), `GroupsCSVImportTests`
  (the two file shapes, an unknown username, a student in two groups in one
  file is refused), and a route test per form.

Nothing in this slice needs LEARN. A course can run its whole term on a file.

## Slice 2: the LEARN source

- `LearnSectionSyncService` becomes `LearnGroupSyncService`. It reads the
  source from the set rather than from `brightspaceSectionCategoryID`, writes
  through `CourseGroupStore`, and stops writing `brightspaceSection`. A
  migration makes one `learnGroups` set from a non-null category ID so an
  existing binding keeps working.
- The BrightSpace tab gets the picker the 0.4 change deferred: a list from
  `fetchGroupCategories` and, new, from `fetchSections`; choosing one creates
  the set. A "Sync now" button runs one course's sync in the request, so an
  instructor does not wait ten minutes to see the result.
- `BrightSpaceAPIClient.fetchSections` reads
  `lp/(v)/(orgUnit)/sections/`. Verify the field names against the Valence
  reference first. `BrightSpaceGrading` gains the method and the no-op client
  returns `[]`, as for groups.
- Tests with a fake `BrightSpaceGrading`: a first sync, a rename, a member who
  moves, a group that disappears, a student the classlist cannot match.
  Today the sweep has no tests at all.

## Slice 3: per-group schedules

This is the slice with the largest blast radius, and the reason to build the
model first.

- The table and `APIAssignmentGroupSchedule`.
- One resolver. `AssignmentDeadlineService` already has `effectiveDueAt(for:
  user:on:)` and `laterDeadline`. The group lookup goes inside
  `effectiveDueAt`, and every student-facing read of `assignment.dueAt` goes
  through it. Today `assignment.dueAt` is read in 29 files under
  `Sources/APIServer/` and `effectiveDueAt` at 3 sites. The student-facing
  readers to move: `WebRoutes+IndexRows`, `CourseItemRow`,
  `StudentCourseRoutes+History`, `WebRoutes+Notebook`,
  `WebRoutes+NotebookPreview`, `GitHubSubmitContext`, `WebRoutes+SlipDay`,
  `SlipDayStore`, `AchievementEvaluationService`, and the two gate functions in
  `AssignmentDeadlineService`. Staff and MCP readers keep the assignment value
  and say "course deadline" where a group may differ.
- `postDeadlineRevealDeadline` takes the latest group `due_at` as its baseline
  (decision 8).
- `opens_at` folds into `assignmentVisibleToStudentByState`: a student in a
  group whose window has not opened sees the row greyed with the open time,
  the way a locked lab shows its prerequisite (docs/unlockable-labs.md).
- The edit page gets one row per group under the due date: open, due, each
  optional, instructor only (the same floor as the due date). A schedule for a
  removed group is shown struck through and can be deleted.
- A deadline is a `dueAt` to the BrightSpace and AGS grade push only through
  the grade, so the push does not change.
- Tests: the resolver table (no schedule, a group due, a group due plus a
  later extension, a group due plus an earlier extension that is still active,
  a student in no group), the reveal rule, and the open window.

## Slice 4: staff in groups

- The Groups tab lets an instructor put a TA in a group. The membership table
  is the same; the row's user has role `ta`.
- `InstructorDashboardRoutes+Students` and the per-assignment submissions list
  read the viewer's groups. When the viewer is a TA with at least one group,
  the default filter is "my groups" and a control shows "all". An instructor
  sees all by default.
- The audit log already records grading actions with the actor. No change.

## What this does not do

- It does not hard-scope a TA (decision 9).
- It does not make a group the scope of a leaderboard, a round robin or a
  class composite. Each of those reads "the course" today
  (docs/class-activities.md, docs/class-composite.md). A group of 25 is the
  natural size for all three, and slice 5 would add an optional group set to
  the `activity` block. The leaderboard page would then render one table per
  group.
- It does not give a group a shared dataset seed. The course cohort
  (docs/datasets-course-library.md) stays per student.
- It does not create groups in LEARN. The direction is read-only, as the
  classlist is.

## Open questions for the maintainer

1. Decision 8: does the reveal wait for the last group, or for the student's
   own group?
2. In the UW LEARN site, are the lab groups D2L Sections or a Group category?
   This decides whether slice 2 needs `fetchSections` first or at all.
3. Should a student who is in no group see the assignment's course deadline
   (the proposal), or should an instructor be warned at save time that a
   scheduled assignment has unassigned students? The proposal does both: the
   course deadline applies, and the edit page counts the unassigned students
   beside the schedule rows.

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
- University of Arizona, exporting grades for one section or group:
  <https://help.intech.arizona.edu/article/557-useful-classlist-features>
