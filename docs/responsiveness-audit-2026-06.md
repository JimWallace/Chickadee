# Responsiveness Audit — June 2026

> **Status: fixed.** Everything below except the two explicitly-deferred items
> (assignment-editor 768px pass with a real suite; hands-on extension-flow
> check with seeded data) was fixed in the same PR as this audit. The live
> check was re-run after the fixes: **zero horizontal overflow on every
> reachable page at both 375px and 768px**, and a 1280px spot check confirmed
> desktop is unchanged. The findings are preserved as written for the record.

Follow-up audit of the responsive first pass described in
[responsive-design-plan.md](responsive-design-plan.md) ("first pass complete —
ready to deploy and fine-tune"). Two methods:

- **Static sweep** of all 41 Leaf templates, their page-local `<style>` blocks,
  `Public/styles.css`, and the JS that renders rows/modals
  (`suite-table.js`, `test-editor-modal.js`).
- **Live check** against a running server (SQLite, local auth, one admin user,
  otherwise empty data): every reachable page loaded headless at **375 px** and
  **768 px**, measuring `document.scrollWidth − clientWidth` and capturing the
  widest offending elements.

Because the live run had near-empty tables, its overflow numbers are a **lower
bound** — real timestamps, usernames, and course rows only make things wider.

## What the live check confirms is working

At 375 px, with no horizontal body overflow: student dashboard (`/`),
`/account`, `/enroll`, `/testsetups/new`, `/admin/runners`, `/admin/workers`,
`/admin/audit`, login/register. Nav wrapping, `.main`/`.form` intrinsic
sizing, and the `.col-hide-phone` mechanism all behave as designed — on
`/admin/users` the Last Seen / Joined columns are correctly hidden (but see
finding 2). Phases 0–2 of the plan hold up on the pages they covered.

## High — live-confirmed horizontal body overflow at 375 px

These pages overflow **even with empty/near-empty tables**. None of them were
in the plan's Phase 3 scope; they need the same treatment the runner/audit
pages got (`.table-scroll` wrapper and/or `.col-hide-*`).

| # | Page | Overflow (375 px) | Root cause |
|---|------|-------------------|------------|
| 1 | `/admin` overview (`admin.leaf`) | **+481 px** (and +96 px at 768 px) | Workers table: 7 columns, all `th` nowrap via the page's sortable-header CSS, no `.table-scroll`. Plus the worker-secret form `.toolbar--nowrap` (`admin.leaf:174`) holding a 16 rem input + two buttons that can never wrap. Courses table (5 cols) also unwrapped. |
| 2 | `/admin/users` (`admin-users.leaf`) | **+135 px** (and +9 px at 768 px) | Phase 3's col-hide *is* applied and working, but the remaining row — name, username, inline role `<select>` + Save form, edit/delete buttons — still needs ~510 px. `#users-table th[data-sort-key] { white-space: nowrap }` (`admin-users.leaf:91`) contributes. The plan marked this page done; it isn't, quite. |
| 3 | `/admin/mcp` (`admin-mcp.leaf`) | **+355 px** | Two tables with no responsive handling: service accounts (4 cols, complex courses cell) and connected agents (**7 cols**, three nowrap `.time` columns). Also `.mcp-username-input { width: 260px }` (`admin-mcp.leaf:221`). |
| 4 | `/agents` (`connected-agents.leaf`) | **+346 px** | Connected-agents table, 6–7 columns (Agent, Authorized by, Scopes, Authorized, Last used, Expires, Status), three nowrap `.time` columns, no wrapper. Instructor-facing, not just admin. |
| 5 | `/admin/storage` (`admin-storage.leaf`) | **+229 px** | 6-column table, nowrap sortable headers; header row alone exceeds 375 px. |
| 6 | `/admin/retention` (`admin-retention.leaf`) | **+223 px** | Fixed column widths `11rem + 7rem + 11rem` (`.retention-col-*`) before content; `.retention-actions { flex-wrap: nowrap }`. |
| 7 | `/admin/alerts` (`alerts.leaf`) | **+141 px** | Rules + firings tables unwrapped; `.alerts-webhook-input { min-width: 320px }` (`alerts.leaf:141`) is 85 % of a 375 px viewport on its own. |

`instructor-brightspace.leaf` could not be loaded live (needs BrightSpace
config) but statically matches this class: mapping table with a no-wrap
`.bs-grade-form` row holding an 11 rem input + button in one cell, a 5-column
sync log with `.bs-log-when { white-space: nowrap }`, no wrappers
(`instructor-brightspace.leaf:81–196, 228–230`).

## Medium — interactive flows and content-dependent hazards (static)

1. **Extension/grade-override popup on `course-student-submissions.leaf`.**
   The Phase 2 fix restyled `assignment-submissions.leaf` (`.ext-panel`,
   plus the phone `min-width: 0` relaxation in `styles.css:1042`), but this
   page's variant is a *different*, page-local `.action-panel`:
   `position: absolute; right: 0; max-width: calc(100vw - 2rem)` anchored
   inside the rightmost table cell. Arithmetic says it just fits at 375 px,
   but it was never restyled or verified like its sibling, and a
   `datetime-local` + text input inside a ~340 px popup is tight. Needs a
   hands-on 375 px check of the actual flow (the plan's own Phase 2 exit
   check, applied to this page).
2. **`.publish-form` popup (instructor dashboard).** `min-width: 260px`,
   absolutely positioned from an Actions cell (`styles.css:981`). No phone
   relaxation — the `.ext-details form` media query at `styles.css:1042`
   doesn't cover it. Clipping risk at 375 px.
3. **iOS zoom-on-focus.** `.form-input` is `.875rem` (~14 px)
   (`styles.css:338`), `.editor-input` is `.85rem`. iOS Safari auto-zooms any
   focused input under 16 px, which is jarring on the one flow the plan
   explicitly targets for phones (granting an extension). Fix is a phone-only
   `font-size: 1rem` on inputs (or accept the zoom).
4. **Authoring pages at tablet width (in-scope per the plan's tablet goal).**
   The suite editor renders inputs with inline fixed widths from
   `suite-table.js` (`style="width:12rem"` display-name, `width:4rem` points —
   lines 268/274/305/335); `.section-var-namecell { width: 14rem;
   white-space: nowrap }` (`styles.css:1514`) plus a full-width value column;
   `.add-test-menu { min-width: 17rem; right: 0 }` (`styles.css:1427–1434`).
   Fine at desktop, increasingly cramped at 768 px with realistic suites, and
   guaranteed overflow at 375 px (phones are explicitly out of scope for
   authoring, so that part is acceptable — but a 768 px pass over
   `assignment-edit.leaf` with a real suite has not been done and should be).
5. **`instructor-students.leaf` filter** `width/min-width: 220px`
   (`instructor-students.leaf:110`) — predates the `.filter-input`
   mechanism; should adopt it (`--filter-width` + full-width on phone).

## Low

- `.time` columns are globally `white-space: nowrap`; harmless where the table
  is wrapped or columns are hidden, but it's the multiplier behind most of the
  header-only overflows above.
- `.suite-child-indent { white-space: nowrap }` (`styles.css:1645`) — long
  user-entered script names can't wrap in the suite tree.
- Known deferred item from the plan, still open: the notebook iframe still
  *loads* JupyterLite/Pyodide in the background on phones even though it's
  hidden (`notebook.leaf`); wasteful, not broken.
- `test-editor-modal.js` card is `min(960px, 96vw)` — shrinks correctly, but
  the family-editor grid inside collapses to one column and gets long rather
  than broken. Acceptable.

## Suggested fix order

1. **"Phase 3b" — the seven uncovered admin/instructor tables** (findings 1–7
   plus BrightSpace): mechanical application of the existing `.table-scroll`
   wrapper and/or `.col-hide-*` classes, exactly as already done for
   runner/audit. Include the three page-local nowrap/no-wrap rules
   (`.toolbar--nowrap`, `.alerts-webhook-input`, `.retention-actions`) getting
   phone-scoped relaxations, and `.mcp-username-input`/`.students-filter`
   adopting `.filter-input`.
2. **Finish `/admin/users`**: wrap in `.table-scroll` or let the role form
   wrap/stack on phone.
3. **Verify the extension flow live at 375 px** on both submissions pages;
   align `course-student-submissions`' `.action-panel` with the `.ext-panel`
   pattern if it misbehaves; give `.publish-form` the same phone relaxation.
4. **Phone input font-size** to 1 rem inside the ≤640 px block (iOS zoom).
5. **768 px pass over the assignment editor** with a realistic suite; relax
   the inline JS widths / `.section-var-namecell` only if that pass shows
   real breakage.

## Method notes (for re-running)

Server: `AUTH_MODE=local ENABLE_NON_SSO_AUTH_MODES=true DATABASE_PATH=<tmp>
.build/debug/chickadee-server serve` from the repo root (Leaf resolves views
relative to the working directory). First registered user becomes admin.
Headless Chromium via Playwright; per page, compare
`max(documentElement.scrollWidth, body.scrollWidth)` to `clientWidth` and dump
elements whose bounding rect exits the viewport. The pages that need seeded
data for a meaningful check (populated student dashboard, submissions +
extension popup, assignment editor with a real suite) are the residual manual
matrix from the plan.
