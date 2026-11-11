# Assignment types: Assignment, Lab, Class activity

**Status: decided 2026-11-10; phases 1 to 3 shipped (phase 1 in #2983, phases 2 and 3 together).** The maintainer took the
recommendation on each decision that was marked "open" (see "Decisions").

## The problem

A course has three kinds of graded work, and each one needs different rules:

| Type | Why it exists | Grading | Secret tests | Counts for marks |
|---|---|---|---|---|
| Assignment | individual work for marks | native worker | must stay hidden | yes |
| Lab | the whole class works at once, in a lab session | student browser | readable in the browser, which is acceptable | participation |
| Class activity | live, synchronous content for about 150 students | either, as the activity kind allows | not relevant | no |

Chickadee has no field for this. Today the type is implied by three signals,
and none of them was designed to carry it:

- `gradingMode` in the manifest (`TestProperties.gradingMode`). The `set_grading_mode`
  tool text and the setup page tooltip already call a browser grade "a
  participation grade" (`SetGradingModeTool.swift:38`, `AssignmentsPage.swift:123`).
- `activity` in the manifest. A non-nil block makes an assignment a class
  activity (`docs/class-activities.md`, decision 1).
- The course section's `defaultGradingMode`, which an assignment takes on
  quietly when it moves into the section (`SectionPlacement.swift:53`).

Because the type is only implied, three things go wrong:

1. **Nothing protects an Assignment's secret tests.** A browser-graded setup
   ships every suite script except grader-only files, so release and secret
   tests are readable in the developer tools (`docs/grading-integrity.md`).
   If an Assignment is moved into a browser-default section, it becomes
   browser-graded without any warning, and its secret tests leak.
2. **"Not graded" is not represented.** Class activities are graded by design
   (`docs/class-activities.md`, decision 1). They reach the BrightSpace push and
   slip days like any other assignment. The only opt-outs are giving every
   entry 0 points and setting `brightspaceSyncExcluded` by hand.
3. **The UI cannot tell the three apart.** Every course row shows the same
   clipboard icon (the request that led to this note). A row that is both a
   lab and an activity, such as HLTH 230 Lab 4b (browser-graded, `bestMetric`),
   cannot be classified from the signals at all.

## Proposal

Add one declared field, `assignmentType`, with the values `assignment`, `lab`
and `classActivity`. It follows the same rule as language (#1331): **the author
declares it and nothing infers it**, except a one-time backfill at the
migration boundary.

### What the type controls

| | Assignment | Lab | Class activity |
|---|---|---|---|
| Default grading mode on create | worker | browser | worker |
| Browser grading allowed | **no** (open 1) | yes | if the activity kind allows it (today's coherence rules) |
| Worker grading allowed | yes | yes (a C++ or Java lab must use it) | yes |
| `activity` block | optional | optional (Lab 4b) | **required** (open 3) |
| BrightSpace / LTI push | yes | yes | **no** (open 2) |
| Slip days | yes | yes | no: the live window replaces a deadline (open 2) |
| Achievements, leaderboard, `metric` | unchanged | unchanged | unchanged |
| Row icon and tile colour | clipboard-check, teal | flask, indigo | users, magenta |

The type takes nothing away from today's coherence rules
(`ManifestCoherence.swift`). An upload-only language still forces worker
grading, and an activity whose opponent needs the worker still refuses the
browser. The type adds one rule on top, in the same place, so every door
(the web editor, MCP, a bundle import, a section move) enforces it.

### Course sections

*(Superseded by phase 3, below.)* The first plan kept the section's
`defaultGradingMode` and ran its adoption through the type's rules. Phases 2
and 3 shipped together instead, so a section has no grading mode at all:
grading follows the type, and a section names an optional default type.

### Storage (open 4)

The recommendation is a **database column** on `assignments`
(`assignment_type`), like `concept` and the BrightSpace fields. It is nullable,
as every column added to an existing table is, and the backfill fills it; a
missing or unknown value reads as `assignment`, the type whose secret tests
stay on the worker. Reasons:

- The type is about course policy and presentation. Changing it should not
  create a new manifest version or re-run validation.
- The row builders read assignment columns already. The admin, BrightSpace and
  MCP rows do not decode the manifest.

The cost: the field must be added to `BundledAssignment` (export, import) and
to clone (`AssignmentAuthoringService.swift:277`), and assignment snapshots do
not version it. The other option is a manifest field next to `gradingMode`,
which would travel with snapshots and bundles for free, but every row that
shows an icon would then have to decode the manifest.

### Backfill

The migration declares a type for every existing assignment once, using
signals that already exist and never the title:

1. Effective grading mode is browser → `lab`.
2. Otherwise, `activity` is non-nil → `classActivity`.
3. Otherwise → `assignment`.

Applied to HLTH 230-W27 (checked through MCP on 2026-11-10):

| Rows | Signals | Backfilled type |
|---|---|---|
| Assignment 0–4 | worker, no activity | assignment |
| Bug Hunt 1, Bug Hunt 2 | worker, no activity (in browser-default sections) | assignment |
| Lab 0–9, Midterm and Final Exam Practice Labs | browser, no activity | lab |
| Lab 4b | browser, `bestMetric` activity | lab |
| The five "Class Activity: …" rows | worker, an activity | classActivity |

If the default points of the five class activities feed the gradebook now,
the backfill changes what the LEARN push sends for them (open 2). The
migration should report how many rows it set to each type.

### Surfaces

- **Authoring:** a Type select at the top of the assignment edit page's
  options block (`POST /instructor/:assignmentID/assignment-type`, instructor
  floor `CourseRoleFloor.assignmentLifecycle`). MCP reads `assignmentType` in
  `get_assignment` and sets it with `update_assignment`. Phase 2 adds the type
  to the new assignment page and `create_assignment`, where choosing Lab or
  Assignment sets the default grading mode, and lists each type's rules in
  `get_server_info`.
- **Creation:** every door that creates an assignment row records a type at
  once. `NewAssignmentFields.assignmentType` has no default, so the compiler
  finds a new door. The new assignment page, quick publish and MCP
  `create_assignment` record `AssignmentType.derivedDeclaration` of the
  setup's manifest (the backfill rule), the clone copies the source's type,
  and a bundle import takes the bundled type or derives it.
- **Rows:** the instructor dashboard (`CourseItemRow.swift`), the student
  course page (`IndexPage.swift`) and the admin course page each pick the icon
  and tile colour from the type. The colours are new `--kind-lab-*` and
  `--kind-activity-*` tokens in light and dark mode, next to `--kind-graded-*`.
- **Docs:** `docs/class-activities.md` decision 1 changes ("an activity is an
  assignment" stays true, but a Class activity no longer pushes a grade).
  `docs/grading-integrity.md` records the browser guard for Assignments.
  `docs/feature-interactions.md` gets a row for the new shared field.

## Phases

1. **The field and the icons.** Migration and backfill, the edit-page select,
   MCP read and write, bundle and clone, row icons and colours. No behaviour
   changes yet, so this is safe to deploy mid-term.
2. **The rules.** The browser guard for Assignments, Class activities removed
   from the LEARN push and slip days, the `activity` requirement for Class
   activities, and the section-move message. Until then the type can drift
   from the manifest: a grading-mode, language or activity edit after creation
   leaves the declared type as it was (`docs/feature-interactions.md`). Phase 2
   closes that by making those writers check the type, and it adds an audit
   record to each type change.
3. **Sections.** `defaultAssignmentType` on course sections replaces
   `defaultGradingMode`.

## What shipped in phases 2 and 3

**The rules** are in `ManifestCoherence.typeViolations`, next to the manifest
rules, so every door that checks those checks these:

- An Assignment refuses browser grading, read as the effective mode (a stored
  `browser` on an upload-only setup grades on the worker and breaks nothing).
  Refused by `set_grading_mode` and the web grading-mode edit, by a
  submission-mode or language edit that would make browser grading effective,
  by a version restore and by a type change to Assignment on a browser-graded
  setup.
- A Class activity needs an `activity` block. Removing the activity is
  refused, and so is a type change to Class activity on a setup without one.
  A new Class activity (the new-assignment page, `create_assignment`) starts
  without its block, because the activity editor is on the edit page; until
  `set_activity` adds one, `check_assignment` reports it as a
  `manifest.incoherent` error.
- Each rule refuses only what an edit introduces, never what a row inherits,
  as the manifest rules do. Reads, grading and pages are never refused.
- A Class activity's grades skip the BrightSpace sweep, the BrightSpace result
  flag and grade-clear sweep, the frozen class-goal requeue and the LTI AGS
  sweep; its points stay in Chickadee. Slip days are
  not offered on it, and no claim window holds its post-deadline reveals.
- A type change goes through `AssignmentTypeChange.apply` (the edit page's
  Type select and MCP `update_assignment`), which checks the rules and writes
  an `assignment.type_changed` audit record.
- The clone and the bundle import copy the type, except that an Assignment
  that the copied manifest grades in the browser becomes a Lab
  (`admissibleAssignmentType`). A Class activity with no activity is copied as
  it is.
- `get_server_info` lists each type with its rules (`assignmentTypes`), in the
  same sentences the edit page and the new-assignment page show
  (`AssignmentTypeRules`).

**Creation.** The new-assignment page has a Type select; the type sets the
grading mode (Lab: browser; Assignment and Class activity: worker; an
upload-only language always worker). The select starts on the section's
default type, else Assignment, and follows a section change until the author
picks a type. MCP `create_assignment` takes an optional `assignmentType`;
omitted, it keeps its old behaviour (browser grading and the derived type, a
Lab, or an Assignment for an upload-only language).

**Sections.** A section has an optional default type and no grading mode. A
move changes neither the type nor the grading mode; when the section's default
differs from the moved assignment's type, the move says so (the dashboard
notice, and the `note` of MCP `set_assignment_course_section`). The migration
`AddSectionDefaultAssignmentType` records "lab" on every browser-default
section and no default on a worker one, and changes no assignment. The old
`default_grading_mode` column stays, with a database default, until a later
release drops it, so the old color of a blue-green deploy can still read it.
A bundle carries `defaultAssignmentType`, and still writes the old
`defaultGradingMode` for an older importer; a bundle without the type maps
"browser" to a Lab default.

## Existing rows that break a rule

Checked on production through MCP on 2026-11-10. HLTH 230-W27 is the only
course with typed rows.

| Row | Type | Grading | Activity | Rule broken |
|---|---|---|---|---|
| Bug Hunt 1: Blood Pressure Categories (`Da8dat`) | Class activity | worker | none | needs an activity |
| Bug Hunt 2: Dosage Rules (`tVt2Hi`) | Class activity | worker | none | needs an activity |

No Assignment is browser-graded.

**Known exceptions: the two Bug Hunts.** The maintainer decided on 2026-11-10
that both stay Class activities with no grades ("Bug hunts are in-class
activities, they are fine as they are no grades"). Each is meant to be a
collaborative coverage activity, in which the class writes tests together to
cover the whole codebase. They get an activity block when that kind lands,
which is designed separately. Until then they break the activity rule, and
that is expected:

- The rule refuses only a write that introduces the break: a change of type to
  Class activity on a setup with no activity, or the removal of an activity.
  Every other edit of either Bug Hunt is allowed, and reads, grading and pages
  are unaffected.
- `check_assignment` reports each as a `manifest.incoherent` error until the
  activity block is added.
- As Class activities they take no slip days and send no grade to LEARN, which
  is what the maintainer wants.
- A clone or a bundle import copies them as they are.
