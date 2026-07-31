# Slip days

Student-managed slip days (#1228): a small, fixed budget of self-serve
deadline extensions a student can spend with no staff involvement. This
document is the reference for the semantics, the data model, the role floors,
and the edge cases; the issue carries the original design discussion.

## The mechanic

- A **slip day** is a student-initiated extension of one assignment's
  deadline, drawn from a per-course budget.
- Defaults: **2 days per student per course**, each granting a **24-hour
  extension**. Both are course-configurable (`/instructor/slip-days`).
- Days **stack**: a student may put one day each on two assignments, or both
  on a single assignment. The n-th day on an assignment produces a deadline
  of `dueAt + n × extensionHours`, always counted from the **original**
  deadline — never from the moment of the claim.
- The feature is **off by default**. Enabling it is a per-course choice; no
  existing course changes behaviour on deploy.

## The claim window

A student may claim the next day on an assignment only while `now` is inside
the window they currently hold:

- **First claim:** after the deadline has passed, and before
  `dueAt + extensionHours`.
- **Stacked claim:** while the current slip-day extension is still live
  (before `dueAt + n × extensionHours` after n spends).

Because the extension runs from the original deadline, a claim outside this
window would buy an already-expired deadline — so the offer simply
disappears, with no expiry sweep. The cost, stated in the issue and accepted:
a student who does not open Chickadee within one extension length of the
deadline loses the option silently.

## How enforcement works

Slip days write (or update) an ordinary `APIAssignmentExtension` row and let
every existing gate do its job — the submission gate
(`isAssignmentOpenForUser`), the dashboard visibility filter, and the
release-tier result visibility all honour extensions already. What is new is
the budget, the ledger, and the affordances:

- **Ledger** — `slip_day_spends` (`APISlipDaySpend`): one row per spend;
  a stacked second day is a second row. A refund stamps `refunded_at` rather
  than deleting, so the ledger stays a complete history. Balance =
  `slip_days_per_student + slip_days_adjustment − count(unrefunded spends in
  the course)`. The ledger is course-scoped and courses are per-term, so the
  budget resets naturally at term rollover.
- **Course policy** — three nullable columns on `courses`
  (`slip_days_enabled`, `slip_days_per_student`,
  `slip_day_extension_hours`), read through `APICourse.slipDayPolicy`
  (`SlipDayPolicy.resolve`, Core). Policy travels in the `.chickadee` course
  bundle; the ledger and adjustments deliberately do not (per-term student
  data).
- **Per-student adjustment** — `course_enrollments.slip_days_adjustment`:
  staff grant extras or claw back without touching course-wide policy.

### Concurrency

Stacking means there is no per-assignment UNIQUE constraint to absorb a lost
race, so `SlipDayStore.spend` is genuinely transactional: one transaction
that (on Postgres) first takes a `FOR UPDATE` row lock on the (user, course)
enrollment row — serializing every balance mutation for that student — then
inserts the ledger row and asserts the budget invariant *after* the insert,
rolling back on violation. On SQLite the single-writer lock provides the
serialization; an interleaved loser fails BUSY (fails closed) rather than
double-spending. Refunds run under the same lock. Never call
`SlipDayStore.spend`/`refund` inside an enclosing `db.transaction`.

### Staff extensions take precedence

An extension row that the slip-day ledger did not produce (no unrefunded
spends for that (user, assignment)) is **staff-granted**, and the slip-day
offer is hidden — a student with an accommodation should not be spending slip
days, and the interaction is confusing to explain. The spend path re-checks
this inside the transaction.

The converse — staff editing an extension that slip days *did* produce — is
not detected: a later refund recomputes the row from the slip-day formula
(current policy hours), overwriting the staff edit. Staff who want to convert
a slip-day extension into a longer accommodation should refund the spends
first, then grant the extension normally.

Slip-day-produced extension rows carry `grantedByUserID = nil` and a
`note` of "Slip day (self-serve)" / "Slip days ×n (self-serve)", so the
student drilldown shows where they came from.

## Student experience

- **Nothing changes before the deadline** — no button, no invitation to plan
  around lateness.
- After the deadline, inside the claim window, the dashboard row shows a
  **calendar icon** in the actions cell. It links to an explicit
  **confirmation page** (`GET /testsetups/:id/slip-day`) that names the
  assignment, the exact new deadline (`America/Toronto`), the cost against
  the remaining budget, and that the spend is not self-reversible. The
  confirm POSTs to the same URL.
- After a first spend the action stays visible while balance and window
  allow, relabelled "Use another slip day — extends your deadline to …".
- **Balance visibility:** "Slip days: N of M remaining." under the course
  heading on the dashboard, and per-course on `/account`.
- Refusals never write: a stale or hand-crafted POST redirects back to the
  dashboard, and the race-sensitive checks (balance, staff-extension
  collision) are re-run atomically inside the store.

## Instructor experience

The **Slip days** tab (`/instructor/slip-days`, behind
`ActiveCourseStaffMiddleware`):

- **Course settings** (enable, days per student, hours per day) —
  per-course **instructor** floor (`requireCourseWriteAccess(atLeast:
  .instructor)`): this is course policy, like enrollment and deadlines. A
  course preferring a chunkier unit sets hours to 48 and the budget to 1.
- **Roster ledger** — every student-role enrollment with used/remaining,
  adjustment, and each spend (assignment, resulting deadline, refunded
  state).
- **Adjust (±1)** and **Refund** — per-course **TA** floor, matching the
  extension grant: an individual accommodation, sibling to grade-override.
  A refund recomputes the extension to `dueAt + remaining × hours` (current
  policy hours) or deletes it when no unrefunded spends remain, so the
  student never keeps the extension for free.

## Edge cases and deliberate limits (v1)

- **Per-assignment opt-out is out of scope.** In a course with slip days
  enabled, every assignment with a deadline is slippable — including one an
  instructor closed manually before the deadline, once that deadline passes
  (indistinguishable, after the fact, from the automatic sweep's close). A
  course that needs one hard mid-term deadline has no way to express that in
  v1 short of leaving the feature off; if that bites, a `slip_days_allowed`
  flag on the assignment is the first follow-up.
- **No stacking cap beyond the budget.** With the default 2-day budget,
  stacking is naturally bounded at 48 h.
- **Changing `extensionHours` mid-term** does not rewrite existing extension
  rows; the new value applies to new spends and to refund recomputes.
- **Changing the assignment's due date** after a spend likewise does not
  rewrite the extension; a refund recomputes from the current due date.
- **A student with no submission can still claim** — the point is more time,
  not a reward for partial work.
- **Preview assignments and staff viewers** never see the offer; archived
  courses refuse spends.
- Submissions arriving in the slip window grade and BrightSpace-sync like
  any other late-window (extension) submission.

## Audit and export

Every mutation is audited: `slip_day.spent` (student actor),
`slip_day.refunded` and `slip_day.adjustment_changed` (staff actors, student
named in `metadata.student_username`, included in the student's data export
via `metadataSubjectActions`), and `slip_day.settings_changed` (course
scope). The student's ledger rows appear in `grading-adjustments.json` of
the personal data export.
