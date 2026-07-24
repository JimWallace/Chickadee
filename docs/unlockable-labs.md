# Unlockable Labs — Assignment Prerequisites & Progression

Design for issues #59 (prerequisite graph) and #62 (unlockable progression),
the two still-open children of epic #49. Decisions below were locked with the
maintainer on 2026-07-23; this document is the source of truth for semantics
until the slices land. It deliberately reuses the intra-assignment test
dependency model (`dependsOn` in the suite editor) at the assignment level.

## Summary

Instructors chain assignments ("labs") with prerequisite edges, authored by
drag-and-drop on the instructor assignments list using the same gesture as the
suite editor (drop a row onto the middle of another row to adopt it as a
prerequisite). A dependent lab stays **locked** for a student until their best
grade on **every** prerequisite reaches 100%. Unlocks are **sticky**: once
earned they are persisted per student and never automatically revoked. Course
staff bypass locks everywhere. The feature is additive and per-assignment
opt-in — a course with no edges behaves exactly as today, so there is no
feature flag (the lesson from the #49 restructure: per-assignment,
instructor-authored beats global flags).

## Locked decisions

1. **Sticky unlocks, persisted.** A `assignment_unlocks` row is written when a
   student qualifies and is never auto-deleted. Rationale: the assignment-
   revision retest loop (v0.4.93, plus MCP content-edit auto-regrade) can drop
   a student below 100% after a suite edit; computing lock state live would
   re-lock a lab the student is actively working in and strand their notebook.
   Sticky rows also give the future lab map (#66) its `unlockedAt` timestamps.
2. **Locked labs are visible, greyed.** The dashboard row renders with a lock
   and "Unlocks after: Lab 2 (your best: 80%)" — students see the path ahead.
   Hidden-until-unlocked was rejected: no visible goal, and the lab map needs
   the full graph anyway.
3. **Authoring is per-course `instructor`-only.** Suite `dependsOn` is content
   (TA-authorable), but a prerequisite edge is availability control, like
   deadlines and open/close — a bad edge locks out the whole cohort. Gate with
   `requireCourseRole(atLeast: .instructor)`.
4. **Per-student staff override ships in v1.** An "Unlock now" action on the
   instructor student view inserts an unlock row with `source: staff`. It is
   the answer to every "the prerequisite closed before they passed" case
   without touching grades.
5. **The predicate is the shared best-grade fold == 100.** Reuse
   `bestGradePercent` / `bestGradePercentBySubmissionID`
   (`Sources/APIServer/Helpers/BestGradePercentBySubmissionID.swift`) — the
   same definition the dashboard, the built-in Ace achievement
   (`grade ≥ 100`), BrightSpace push, and the grades CSV use. That grade is
   points-weighted over the full all-tier collection and **rounded**
   (199/200 points rounds to 100). We accept the rounding for platform
   consistency rather than inventing a stricter `earned == total` rule.
6. **Edge table, not a parent column.** Multi-prerequisite AND semantics are
   supported by the schema from day one; the v1 drag UI only authors
   single-parent chains (same as the suite editor, where `dependsOn` is an
   array but the gesture sets one parent). A nullable per-edge
   `threshold_percent` (nil ⇒ 100) is included now, following the house
   "gamification fields present from day one but nullable" precedent, so the
   epic's extended triggers don't need a migration.
7. **Same-section is an editor-UX constraint only.** Mirroring the suite
   editor: the adopt gesture only fires within one course section, but the
   server validates same-*course* (plus acyclicity), not same-section, so
   moving an assignment between sections never breaks the graph.

## Data model (additive)

### `assignment_prerequisites` — the edge table

| column | type | notes |
|---|---|---|
| `id` | UUID | PK |
| `assignment_id` | UUID | FK → assignments, cascade delete (the dependent) |
| `prerequisite_assignment_id` | UUID | FK → assignments, cascade delete |
| `threshold_percent` | INT NULL | nil ⇒ 100; reserved for later "unlock at ≥ N%" |

Unique on `(assignment_id, prerequisite_assignment_id)`.

Validation at write time (422 on violation, matching the suite editor):
same course, no self-edge, no duplicate, and no cycle — Kahn's algorithm over
the course's authored edges, mirroring `detectAuthoredCycles` in
`Sources/APIServer/Utilities/PatternFamilyApplication.swift`.

Cascade delete means deleting a prerequisite assignment silently removes its
edges (dependents unlock) — the analogue of the suite editor pruning deps.

### `assignment_unlocks` — sticky per-student state

| column | type | notes |
|---|---|---|
| `id` | UUID | PK |
| `user_id` | UUID | FK → users, cascade delete |
| `assignment_id` | UUID | FK → assignments, cascade delete |
| `unlocked_at` | datetime | for the lab map / analytics |
| `source` | string enum | `auto` \| `staff` |

Unique on `(user_id, assignment_id)`. Template: the existing per-(user,
assignment) tables (`CreateAssignmentParticipations`,
`CreateAssignmentPersonalizationSeeds`) — cascade FKs, thin store with a
race-safe upsert (unique-violation tolerated, first writer wins). The name is
deliberately distinct from `secret_reveal_unlocks` (unrelated feature).

## Unlock semantics

A pure, unit-testable evaluator plus a store:

- **Locked** for a student ⇔ the assignment has ≥ 1 prerequisite edge AND no
  `assignment_unlocks` row for that student. No edges ⇒ never locked.
- **Qualified** ⇔ for every edge, the student's best grade on the prerequisite
  ≥ (`threshold_percent` ?? 100), using the shared fold above.
- **Write paths.** (a) At result-persist time — both the worker path
  (`ResultRoutes`) and the browser path (`BrowserResultRoutes`), the same two
  sites that already run `awardClassBadgesFor100Percent`: after a result lands,
  evaluate the graded assignment's *dependents* for that student and insert
  rows for any that now qualify. (b) **Lazy backfill on read** — the dashboard
  row builder and the gate check both re-evaluate when no row exists and
  insert one if the student currently qualifies. Backfill is what makes grade
  overrides, edges added after a student already qualified, course-bundle
  imports, and mid-term enrollment all "just work" without event plumbing.
- **No auto re-lock.** Adding a new edge to an assignment does not revoke
  existing unlock rows. If an instructor truly needs to re-lock, that is a
  future explicit action, not implicit behaviour.
- Validation-kind submissions never write unlock rows (staff-side, and the
  gate is student-only anyway).

## Enforcement

- Extend `AssignmentSubmissionGateError`
  (`Sources/APIServer/Services/AssignmentDeadlineService.swift`) with a
  distinct locked case (403) whose message names the unmet prerequisite(s).
  (#63 shipped with a single `.closed` case; this introduces the
  distinct-reason pattern its issue originally asked for.)
- Compose the check inside the shared gate — `requireOpenStudentAssignment` /
  `isAssignmentEffectivelyOpen` — ANDed with visibility and `startsAt`. Staff
  bypass mirrors the existing `submissionGate(isStaff:)` /
  `honorsStartDate: !isStaff` pattern (`Sources/Core/AssignmentVisibility.swift`).
- Because every student-facing chokepoint already routes through that gate,
  lock enforcement lands everywhere at once: web submit form GET/POST
  (`WebRoutes+Submission.swift`), notebook page / JupyterLite source / reset
  (`WebRoutes+Notebook.swift`), browser-runner download / manifest / seed
  (`BrowserRunnerRoutes.swift`), browser result submits
  (`BrowserResultRoutes.swift`), and the read-only `closedAssignmentGate`
  (`NotebookWorkingCopyStore.swift`). Vanity URLs resolve and redirect into
  these handlers.
- **Precursor fix (ships first, independently):** `POST /api/v1/submissions`
  and `/file` (`Sources/APIServer/Routes/SubmissionRoutes.swift`) only check
  enrollment — the v0.4.52 late-submission guard never covered the raw API
  path, so closed/late submissions are possible today by bypassing the web UI.
  Route them through `requireOpenStudentAssignment`; the locked check then
  inherits the fix.

## Student-facing UX

- Dashboard row (built in `WebRoutes+IndexRows.swift`
  `buildTestSetupRow` / `StudentAssignmentRowContext`): greyed, lock icon,
  "Unlocks after: Lab 2 (your best: 80%)" listing every unmet prerequisite
  with the student's current best grade, and no notebook/submit actions. The
  per-prerequisite progress is the motivation loop — it shows exactly how far
  from unlocking they are.
- A direct or vanity link to a locked assignment renders a friendly locked
  page (403), naming the prerequisites — never a bare error.
- Styling per house rules: design tokens only, reason conveyed in text (never
  colour alone, per the AODA pass), dark-mode via existing palette vars;
  `scripts/check-styles.sh` guards apply. If `index.leaf` needs decomposition,
  remember the one-inline-`#extend`-per-template LeafKit limitation.

## Instructor authoring UX

- On the instructor assignments table (which already drag-reorders): top/bottom
  thirds keep meaning reorder; the middle third becomes the adopt zone —
  ported from `Public/suite-table.js` (`drop-adopt`, single parent, and the
  `connectedDependencyGroup` behaviour so dragging a parent moves its cluster).
  Dependents render one level indented under their parent within a section.
- Persistence is server-authoritative, matching `PUT /instructor/:id/suite`:
  the client PUTs the authored order + edges, the server validates
  (cycle/self/duplicate/course) and returns the reconciled state.
- Non-blocking editor warnings when a prerequisite:
  - has release/secret-tier points — students could be blocked by failures
    they cannot see (labs should normally be public-tier only);
  - has zero graded points — 100% is unreachable, the dependent can never
    unlock;
  - has an earlier due date than the dependent — students who miss it are
    locked out permanently (pair with the staff override);
  - is not visible/open to students.
- Instructor student view gains the per-student "Unlock now" action.

## MCP parity

- `get_assignment` reports `prerequisites` (public IDs + thresholds).
- `update_assignment` gains an optional `prerequisites` array of public IDs
  (nil = untouched, `[]` = clear), threaded exactly like `secretRevealEnabled`
  (Input/schema/Output → `AssignmentAuthoringService`), gated per-course
  instructor like the lifecycle fields.
- This is availability metadata, not graded content: it does **not** close the
  assignment and does **not** trigger a regrade (same class as
  `set_grading_mode`).
- Sync surfaces to update in the same PR: `docs/mcp-authoring-roadmap.md`
  (`MCPRoadmapDocSyncTests`), `MCPServerInstructions.text`
  (`MCPInstructionsCatalogSyncTests`), and the output schemas
  (`MCPOutputSchemaSyncTests`).

## Carry-through surfaces

- **Course bundle export/import.** `BundledAssignment`
  (`Sources/Core/CourseBundleManifest.swift`) gains a nullable list of
  prerequisite assignment bundle-IDs (+ thresholds); old bundles decode nil
  and `schemaVersion` stays 1. Import becomes two-pass
  (`CourseBundleRoutes+Import.swift`): create all assignments, build the
  assignment bundle-ID → UUID map (the analogue of the existing
  `sectionIDMap`), then write edges.
- **Admin copy-course** (the `AssignmentAuthoringService.cloneAssignment`
  loop) must remap edges across the copy — otherwise instructors re-author the
  graph every term.
- **Single `clone_assignment`** drops edges, consistent with it already
  dropping due date and section; cross-course clones must drop them.
- BrightSpace sync needs nothing: locked labs simply have no grades yet.

## Explicitly out of scope (later, on this foundation)

- The student lab map tab (#66) — reads the same edge table + unlock rows.
- Extended triggers from the epic: class-completion-% follows the
  `AchievementEvaluationService` periodic-sweep pattern;
  time-under-threshold adds a criteria kind; `threshold_percent` is already
  in the schema. (The achievements condition vocabulary was evaluated and
  deliberately *not* reused for unlock criteria: its signals are strictly
  one-submission-local, with no cross-assignment reference.)
- Unlock notifications/toasts; an achievement/badge tie-in for unlocking.
- Multi-parent authoring UI (the schema already supports AND edges).

## Slice plan (individually mergeable)

0. **Precursor bug fix:** API submission endpoints get the open-assignment
   gate (independent of this feature).
1. **#59:** migrations + models + validation service + unlock evaluator/store
   + unit tests. No behavioural change.
2. **#62 core:** gate composition at the chokepoints, the locked reason case,
   staff bypass, route tests for every entry point.
3. **Student dashboard:** locked rows + the friendly locked page.
4. **Instructor authoring:** drag-to-adopt UI, PUT endpoint, editor warnings,
   per-student "Unlock now".
5. **MCP parity** + the three catalog sync suites.
6. **Carry-throughs:** bundle round-trip, copy-course remap, clone semantics,
   with round-trip tests.

## Test plan (sketch)

- Unit: evaluator predicate (thresholds, multi-edge AND, zero-point
  prerequisite), validation 422s (cycle/self/duplicate/cross-course).
- Route: every chokepoint returns the locked reason for a locked student;
  staff bypass; override insert; API-path gate parity.
- Render: dashboard locked row (with progress text), instructor indent tree.
- Round-trip: bundle export→import preserves edges; copy-course remaps; clone
  drops.
- Regression: a suite-edit regrade that drops a student below 100% does *not*
  re-lock (sticky), and a grade override unlocks via lazy backfill.
