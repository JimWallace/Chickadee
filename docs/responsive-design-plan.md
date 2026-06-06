# Responsive Design Plan

Status: **proposed** (planning only — no CSS/markup changes yet)

## Goal

Make Chickadee's web UI usable on phones and tablets without a framework
migration or a redesign. The bar is **viewing and light data-entry**, not full
authoring:

- **Phones (≤640px):** view summary/list pages (student dashboard, instructor
  dashboard, submissions, account, history) and perform small interactive tasks
  — most importantly **granting a student an extension** (the per-student grade
  override / due-date form on the submissions page).
- **Tablets (641–1024px):** everything phones can do, plus the notebook editor
  (JupyterLite needs room but works with touch).
- **Desktop (>1024px):** unchanged — current layout is the baseline.

Explicit non-goals: making the JupyterLite notebook editor work on a phone, and
making the dense admin tables (runner dashboard, audit log) comfortable on a
phone beyond "readable, no horizontal blowout."

## Why the codebase is ready

The front end is in a good state for additive responsive work:

- **One hand-rolled stylesheet** — [`Public/styles.css`](../Public/styles.css)
  (~26KB), CSS custom properties, `rem`-based sizing throughout. No
  Bootstrap/Tailwind to migrate.
- **One shared layout** — every page extends
  [`Resources/Views/base.leaf`](../Resources/Views/base.leaf), which already
  ships `<meta name="viewport" content="width=device-width, initial-scale=1">`
  (line 5). One change propagates everywhere.
- **The only existing media query is `prefers-color-scheme: dark`**
  (`styles.css:44`). No breakpoint logic to untangle — we are adding the first.
- Flexbox/grid with `flex-wrap: wrap` and `gap` are already the norm.

The three real problems:

1. **Fixed-width containers never relax.** `.main` is `max-width: 900px`
   (`styles.css:199`), `.form` is `620px` (`styles.css:294`), `.auth-box` is
   `420px` (`styles.css:784`), plus inline `style="width:220px"` /
   `style="width:280px"` filter inputs. All applied unconditionally.
2. **Tables have no small-screen strategy.** `.results-table`
   (`styles.css:483`) is `width: 100%` with no overflow handling; the app is
   table-heavy and some admin tables run 7–8 columns with hardcoded widths.
3. **Nav + dense action cells.** The top nav (`base.leaf:22`) crowds on small
   screens; per-row action buttons and `.action-btn` icon buttons
   (`styles.css:276`, ~0.8rem) are below comfortable tap-target size (44px).

## Approach decisions (locked)

- **Table strategy: hide non-essential columns** below the breakpoint (chosen
  over horizontal-scroll and card/stack). Each table gets a per-column priority;
  low-priority columns are `display: none` on phones. Essentials stay; the row's
  detail link still leads to the full record. See
  [Column priorities](#table-column-priorities) below.
- **Mobile-first additive, not a rewrite.** Desktop rules stay as the default;
  we add `@media (max-width: …)` blocks that override. No existing selector is
  deleted.
- **No JS framework, no nav JS yet.** First pass makes the nav *wrap* cleanly
  rather than introducing a hamburger menu. Revisit a hamburger only if wrapping
  proves insufficient (see Phase 1 exit check).

## Breakpoints

Two breakpoints, defined once as a comment-documented convention (CSS custom
properties can't be used inside `@media` conditions, so these are literal but
centralized in one block at the top of the stylesheet):

| Name    | Range            | Media query                  |
|---------|------------------|------------------------------|
| phone   | ≤ 640px          | `@media (max-width: 640px)`  |
| tablet  | 641px – 1024px   | `@media (max-width: 1024px)` |
| desktop | > 1024px         | (default, no query)          |

`max-width` (desktop-first overrides) is chosen because the existing CSS *is*
the desktop layout — we layer reductions on top rather than rebuilding up.

## Phases

### Phase 0 — Foundation (no visible desktop change)

A single PR that establishes the breakpoint scaffolding and fixes the
unconditional width traps. Nothing should change at >1024px.

- [ ] Add a documented "Responsive breakpoints" banner comment + the two
      `@media` blocks (initially near-empty) at the end of `styles.css`.
- [ ] In the phone block: `.main { max-width: 100%; padding: 0 1rem; margin: 1rem auto; }`.
- [ ] In the tablet block: relax `.form { max-width: 100%; }` and
      `.form--wide` already has none.
- [ ] Replace inline fixed-width filter inputs (`style="width:220px"` in
      `admin-users.leaf`, `style="width:280px"` in `assignment-submissions.leaf`)
      with a `.filter-input` class that is a fixed width on desktop and
      `width: 100%` on phone. (Keeps markup honest; avoids `!important`.)
- [ ] Add `min-width: 0` to flex containers that hold long text (nav username,
      `.assignment-title-cell`, `.submission-header-row`) so long names/emails
      wrap instead of forcing horizontal overflow.
- [ ] Wrap every `.results-table` in a `.table-wrap { overflow-x: auto; }` —
      this is the **safety net** so that even before per-table column hiding
      lands, no table can blow out the viewport. (The column-hiding work in
      later phases removes the *need* to scroll on the priority pages, but the
      wrapper stays as a backstop for the dense admin tables.)
- [ ] Nav: in the phone block, allow `.nav { flex-wrap: wrap; row-gap: .25rem; }`
      and drop `margin-left: auto` on `.nav-username` so items wrap left-aligned.

**Exit check:** Chrome devtools at 375 / 768 / 1024 / 1440 — every page renders
with no horizontal scrollbar on the `<body>`; desktop pixel-identical to today.

### Phase 1 — Summary / read pages (priority)

Pages: `index.leaf` (student dashboard), `assignments.leaf` (instructor
dashboard), `account.leaf`, `submission-history.leaf`,
`course-student-submissions.leaf`, `submission.leaf` (single result view).

- [ ] Apply [column priorities](#table-column-priorities) — add
      `data-priority` / utility classes (`.col-hide-phone`) to non-essential
      `<th>`/`<td>` and hide them in the phone block.
- [ ] Stack `.submission-header-row` (`styles.css:411`) vertically on phone
      (already `flex-wrap: wrap`; ensure the score/badges don't get cramped).
- [ ] Ensure action button groups wrap and meet a min tap target: in the phone
      block, bump `.action-btn { min-height: 2.4rem; }` and ensure ≥6px gaps.
- [ ] `.course-tabs` already `overflow-x: auto` (`styles.css:825`) — verify it
      scrolls cleanly with many courses; no change expected.

**Exit check:** On a real phone (or 375px emulation) a student can read their
dashboard, open an assignment, and read results top-to-bottom with no
sideways scrolling. If the nav wrapping looks bad here, open a follow-up for a
hamburger — do **not** scope-creep it into this phase.

### Phase 2 — The extension / grade-override workflow

The one *interactive* mobile flow called out by the user. Lives on
`assignment-submissions.leaf` — the per-student list whose Actions column holds
the grade-override / extension form, currently an inline `<details>` /
`position: absolute` popup that will overflow a phone viewport.

- [ ] Audit the popup's positioning (look for `position: absolute; right: 0`
      style popups like `.add-section-popup`, `.publish-form` at
      `styles.css:972`). On phone, switch the override form to **static flow**
      (full-width block under the row) instead of an absolutely-positioned
      overlay, so it can't clip off-screen.
- [ ] Form fields full-width; date/number inputs use native mobile pickers
      (`type="date"` / `type="number"` already give good mobile keyboards —
      verify the markup uses them).
- [ ] Submit/cancel buttons full-width-stacked on phone, min 44px tall.

**Exit check:** Grant an extension end-to-end on a 375px viewport without
zooming or horizontal scrolling.

### Phase 3 — Dense admin tables (lowest priority)

Pages: `admin-runner.leaf` (8-col jobs + snapshots), `admin-audit.leaf` (7 cols
with hardcoded `width:` on `<th>`), `admin-users.leaf`.

- [ ] Keep the `.table-wrap` horizontal-scroll backstop from Phase 0.
- [ ] Apply aggressive column hiding (these are desktop-first admin tools): on
      phone keep only the 2–3 identifying columns + the primary metric; hide the
      rest. The full record stays reachable on desktop.
- [ ] Remove/scope the hardcoded `<th style="width:…">` widths in
      `admin-audit.leaf` so they don't force overflow on phone (move to a class
      that only applies the width ≥1024px).

**Exit check:** Admin pages are *readable* on a phone (no body-level overflow);
full comfort is explicitly not required.

### Phase 4 — Tablet-only editor gating

`notebook.leaf` already overrides `.main` to full width and sizes the iframe
`calc(100vh - 9rem)` (`styles.css:766`). JupyterLite is unusable on a phone.

- [ ] In the phone block only, replace the iframe with a friendly notice:
      "The notebook editor needs a larger screen — please open this on a tablet
      or computer." (Show via a `.notebook-smallscreen-notice` block that is
      `display: none` above phone and `display: block` / iframe hidden at phone.)
- [ ] Verify the editor *renders and is touch-usable* at 768px (tablet). No
      layout change expected beyond confirming the toolbar wraps.

## Table column priorities

For the hide-non-essential-columns strategy. "Keep (phone)" columns stay
visible ≤640px; the rest get `.col-hide-phone`.

| Page / table | Keep (phone) | Hide (phone) |
|---|---|---|
| `index.leaf` — assignments | Name, Status/Grade, Actions | Due, History |
| `assignments.leaf` — instructor assignments | Name, Status, Actions | Due, counts |
| `assignment-submissions.leaf` — submissions | Name, Grade, Actions (extension) | Student ID, History |
| `account.leaf` — enrollments | Code/Name, Action | (few cols; likely keep all) |
| `admin-users.leaf` | Name/Username, Role, Actions | Last Seen, Joined |
| `admin-runner.leaf` — jobs | Submission, Status | User, all timing metrics, Peak Disk, Completed |
| `admin-audit.leaf` | Time, Action | Actor, Category, Target, Remote, Metadata |

These are starting points; tune during implementation against real content.

## Testing matrix

Manual, devtools-based (no automated visual regression in this pass):

| Viewport | Device proxy | What to check |
|---|---|---|
| 375px | iPhone SE / mini | No body horizontal scroll; nav wraps; tables show kept columns; extension flow works |
| 414px | larger phone | Same |
| 768px | iPad portrait | Notebook editor usable; tables comfortable |
| 1024px | iPad landscape | Boundary — should look near-desktop |
| 1440px | desktop | **Pixel-identical to today** (regression guard) |

Each phase's PR description should include before/after screenshots at 375px and
1440px for the pages it touches.

## Risks & notes

- **`document.write` after multipart submit** (`base.leaf:122`) replaces the
  whole document. Any responsive CSS lives in the linked stylesheet, so the
  rewritten doc still picks it up — no special handling needed, but worth
  remembering when testing the upload/extension flows.
- **Dark mode interaction:** the new `@media (max-width)` blocks are orthogonal
  to the existing `@media (prefers-color-scheme: dark)` block; they compose
  fine, but test phone layout in both color schemes once.
- **LeafKit partial limitation:** the codebase notes LeafKit 1.x false-positive
  cycle errors prevent some shared partials (e.g. `styles.css:883` comment).
  This plan adds **zero** new Leaf partials — all changes are CSS plus class
  attributes on existing markup — so it sidesteps that entirely.
- **No version bump in PRs.** Per `CLAUDE.md`, add a `changelog.d/` fragment per
  PR; do not touch `VERSION` / `ChickadeeVersion` / `CHANGELOG.md`.
- **SwiftLint/swift-format are not triggered** by CSS/Leaf-only changes, but run
  `scripts/lint.sh` if any Swift is touched (none expected here).

## Suggested PR sequence

1. **Phase 0** — foundation (breakpoints, container relax, `.table-wrap`,
   nav wrap). Low risk, unblocks everything.
2. **Phase 1** — summary pages + column priorities.
3. **Phase 2** — extension/grade-override flow.
4. **Phase 3** — admin tables.
5. **Phase 4** — notebook tablet gating.

Each is independently shippable and independently reviewable.
