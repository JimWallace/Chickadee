# Solution visibility

Post-deadline solution reveal: a per-assignment policy that lets students view
the reference solution (the instructor's answer key) once their deadline has
truly passed. This document is the reference for the semantics, the reveal
gate, the slip-day interaction that shapes it, and the deliberate limits.

## The mechanic

- Each assignment carries a `SolutionVisibility` policy (Core), stored as a
  nullable `solution_visibility` column on `assignments`:
  - **`hidden`** (nil / the default) — the solution stays staff-only, exactly
    the pre-feature behaviour. No existing assignment changes on deploy.
  - **`afterDue`** — each enrolled student may view the solution once *their
    own* reveal moment has passed (below).
- What is revealed is the same artifact staff see: the reference solution
  resolved from the setup zip's `solution.*` entry, the linked validation
  submission, the newest validation submission, or the unvalidated draft
  (`solutionNotebookData` / `solutionFileDownloadResponse`). For a notebook
  assignment the student opens it in the editor — seeded through
  `ensureUserNotebookWorkingCopy`, so `{{name}}` placeholders render with the
  *student's own* personalization, and the answers line up with their variant.
  For an upload-only language (C++, Racket, Java) the solution is a source
  file and is served as a download.
- An assignment with **no due date reveals immediately** while published —
  the posted-lecture-material case. Content items are links rather than
  hosted files, so lecture material with a revealable solution is naturally
  an assignment with no deadline (or a lecture-day one).

## The reveal gate

`solutionVisibleToStudent` (AssignmentDeadlineService) is the single
predicate every student-facing surface consults — the notebook page, the raw
`notebook/source` endpoint, the download route, the dashboard row action, and
the submission-page notice. Staff bypass it unconditionally. All four
conditions, each with its reason:

1. **The policy is `afterDue`.** Off by default; display policy only (no
   manifest change, no regrade, no close).
2. **No manual deadline override is active.** A re-opened assignment accepts
   submissions from everyone, so the reveal is suppressed while the override
   lasts. Students may have already seen the solution before the re-open —
   the edit page's field note says so — but suppressing is still right for
   the common case (re-opening a lab that broke before anyone got far).
3. **The assignment is student-visible by its own state**
   (`assignmentVisibleToStudentByState`): published and open, or
   published-then-closed. A draft, a staff-only preview, or a scheduled
   assignment that has not started can never leak its solution, whatever the
   policy says.
4. **The student's `postDeadlineRevealDeadline` has passed** — the later of:
   - their **effective deadline** (`dueAt` folded with their extension row,
     the same value the submission gate uses), and
   - the end of any **slip-day claim window they could still use**
     (`slipDayClaimWindowCeiling`).

## Why the slip-day half exists

Slip days are claimed *after* the deadline: the first claim window is
`(dueAt, dueAt + extensionHours)`. Gating the reveal on the effective
deadline alone would let a student read the answer key one minute past the
due date, claim a slip day, and submit it for full credit — the student holds
no extension row at the moment they look, so `effectiveDueAt` has passed.

`slipDayClaimWindowCeiling` closes that hole with the window the student
currently holds: `dueAt + max(spends, 1) × extensionHours` while a claim is
reachable (policy on, deadline set, balance ≥ 1, no staff extension, window
not lapsed), nil otherwise. Because claim windows only ever close — a lapsed
offer cannot come back except by a staff refund or adjustment, and the value
is recomputed live — `max(effectiveDueAt, ceiling)` behaves monotonically.
With the default 2 × 24 h policy:

| Student state | Solution appears |
|---|---|
| Slip days off in the course | at `dueAt` (or their extension's end) |
| Balance > 0, never claims | at `dueAt + 24h`, when the offer lapses |
| Claims one day / stacks two | at `dueAt + 24h` / `dueAt + 48h` |
| Staff-granted extension | when their extension ends |
| No due date | immediately |

The same ceiling now also backs **release-tier output**:
`releaseVisibilityDeadline` returns `postDeadlineRevealDeadline`, so the
expected/actual values in release results can no longer be read at due+1min
and acted on with a freshly claimed slip day. This closes a pre-existing gap
in the slip-day feature — release gating honoured extensions once claimed,
but not the claim still on the table — across the web submission view, the
results API, and the personal data export, which all flow through the one
resolver.

## Enforcement chokepoints

- `GET /testsetups/:id/notebook?file=solution` and
  `GET /testsetups/:id/notebook/source?file=solution` — the staff-only throw
  became "staff, or `solutionVisibleToStudent`". The student's solution
  working copy lives beside their assignment copy
  (`users/<uid>/<setup>/solution.ipynb`) and seeds with their substitutions.
- `GET /testsetups/:id/solution/download` (new; session auth + enrollment) —
  streams the resolved solution file with its original filename. The only
  delivery for upload-only assignments, whose notebook page redirects to the
  upload form. The instructor files route stays staff-gated; the notebook
  page's Download button targets the route matching the viewer.
- Affordances render through the same rule: the dashboard row action
  (computed from the row inputs already loaded — no extra per-row queries),
  the notebook-toolbar "View solution" link, and the submission-page notice.
  An affordance can hide while a direct URL would serve (e.g. an archived
  course's ceiling) but never the reverse.

## Authoring

- **Edit page** — a second "Student Options" checkbox, persisted by the
  dedicated lightweight `POST /instructor/:id/solution-visibility`
  (instructor floor), so a mid-semester flip never closes or re-validates the
  assignment. Mirrors the secret-reveal toggle.
- **MCP** — `update_assignment` takes `solutionVisibility` (values derived
  from `SolutionVisibility.allCases` in both schema and prose);
  `get_assignment` reports it.
- **Fail loudly while authoring, never while serving.** Enabling `afterDue`
  is refused — web form error and MCP `invalidArguments` alike — while the
  assignment has no solution on file (`assignmentHasSolution`, the same
  four-source answer the workbench's Solution tab uses). The serving routes
  fail soft (404 with a clear message) if the solution later vanishes, and
  affordances simply do not render when the gate refuses.
- Every change is audited (`solution_visibility.changed`, web path).

## Edge cases and deliberate limits (v1)

- **No participation prerequisite.** Any enrolled student may view a revealed
  solution, submitted or not — matching slip days ("the point is more time,
  not a reward for partial work") and the lecture-material case, where
  nothing is ever submitted.
- **The residual cross-student leak is accepted.** A student whose slip
  balance is zero sees the solution at `dueAt` and could pass it to a
  classmate still holding a claim window. That is collusion-shaped (no
  different from sharing their own correct answers) and strictly narrower
  than what release output did before this change. The airtight alternative
  — reveal for everyone at the maximum over the roster — lets one
  accommodation hide the solution from the whole class indefinitely, and
  makes visibility retreat when an extension is granted late. Rejected.
- **A late accommodation re-hides what was seen.** Granting an extension
  after a student's reveal moment flips their gate back off; the viewing
  already happened. That is inherent to late grants, not a defect the gate
  can fix.
- **Refunds and adjustments recompute live.** A staff refund shrinks the
  ceiling (earlier reveal); a balance adjustment inside a still-open window
  restores it. Both are rare staff actions and the gate simply reflects the
  current state.
- **The reveal is not versioned.** Students see the current solution; an
  instructor updating it post-reveal updates what students open next. A
  student's already-seeded working copy keeps its bytes (same behaviour staff
  have) until reset.
- **Not carried in `.chickadee` course bundles** — matching
  `secretRevealEnabled`, which does not travel either: per-offering display
  policy, re-chosen each term.
- **No per-view record.** A `solution_views` first-view ledger (useful when
  granting a late accommodation: "had this student already seen the answer
  key?") is the natural follow-up if the need materializes; the audit trail
  currently records policy changes only.
