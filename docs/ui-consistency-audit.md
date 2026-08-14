# UI Consistency Audit — the widget layer (2026-08)

An audit of the web UI one level above the design tokens: interactive
widgets, page skeletons, and the JavaScript behaviours behind them. The
token layer (colour / type / radius / spacing) is already guarded by
`scripts/check-styles.sh` and documented in [ui-design.md](ui-design.md);
this audit found that the drift now lives in the layer those guards cannot
see — the *same interaction* implemented two to six different ways on
different pages.

The prompting example was the two "find a person" inputs:
`/instructor/students` filters live as you type, while
`/instructor/activity` is a submit-and-reload GET form with different
labelling, a different input type, and different dress. That example
generalises: this document inventories every family where the same widget
diverged, and lays out an ordered slice plan to consolidate them.

**Method.** Full sweep of `Resources/Views/*.leaf` and first-party
`Public/*.js` (vendored trees excluded), against the archetypes and
component vocabulary in `ui-design.md`. Every count below is backed by
file:line evidence gathered in the sweep; representative references are
kept inline, exhaustive per-site tables are reproduced only where a slice
needs them.

**Ratchet position at audit time** (`scripts/check-styles.sh`):
`PAGE_STYLE_BASELINE=913` and `INLINE_SCRIPT_BASELINE=1968`, both with
**zero headroom** — the actual counts sit exactly at the baselines. Also
`JS_STYLE_DECISION_BASELINE=122`, `ALERT_BASELINE=4`, `JS_ALERT_BASELINE=7`
(all at baseline). Every slice below shrinks at least one of these and must
lower the baseline in the same PR.

---

## Findings

### F1. List filtering / person entry — three patterns for one job

Five list-filter inputs exist, in three unrelated patterns:

| page | pattern | input | labelling | placeholder | clear |
|---|---|---|---|---|---|
| `/admin/users` (`admin-users.leaf:10`) | live client-side | `type=search` `.filter-input` | aria-label only | "Filter by name, username or role…" | native ✕ |
| assignment submissions (`assignment-submissions.leaf:18`) | live client-side | `type=search` `.filter-input` | aria-label only | "Filter by name or ID…" | native ✕ |
| `/instructor/students` (`instructor-students.leaf:55`) | live client-side | `type=search` `.filter-input` | aria-label only | "Filter by name or username…" | native ✕ |
| `/instructor/activity` (`instructor-activity.leaf:25`) | GET form, server-side | `type=text` `.filter-input` | visible label "Filter by person" | "username" | Clear link |
| `/admin/audit` (`admin-audit.leaf:30`) | GET form, server-side | `type=text` `.input-compact` — not `.filter-input` | visible label "Actor contains" | "username" | Clear link |

Behind the three live filters are **three separately hand-rolled
`applyFilter` copies in inline scripts** that do not even match the same
way — two match on whole-row `textContent`
(`instructor-students.leaf:355`, `assignment-submissions.leaf:236`), one
matches three specific columns (`admin-users.leaf:213`). None is shared,
none is debounced.

The three live inputs also carry a
`readonly onfocus="this.removeAttribute('readonly')"` anti-autofill hack —
needed only because they sit outside any `<form>`, so
`app.js:56`'s form-level `suppressSpuriousAutofill()` never reaches them.
`admin-mcp.leaf:64` solves the same problem a third way
(`autocomplete="new-password"` on a username field). Three coexisting
autofill-suppression idioms.

No typeahead exists anywhere for people. The only `<datalist>` mechanism
in the codebase is the D2L grade-object picker, itself duplicated
(`instructor-brightspace.leaf:113` and `_assignment-edit-body.leaf:47`).

The split between live and server-side filtering is **not** itself a
defect: activity and audit filter datasets the server caps (limit 100 and
200 respectively), so client-side filtering would silently search only the
visible page. The defect is that the two models share no visual language,
no labelling convention, and no code.

### F2. Table sorting — three markup dialects, six implementations

A shared component exists — `Public/sortable-table.js`, the documented
`.sortable-table` vocabulary entry (`th > button.sort-header`,
`data-sort-type`, `data-sort-value`) — and is used by 6 tables on 4 admin
pages (admin-runner ×2, admin-storage, admin-retention, admin-mcp ×2).
Alongside it:

- **Dialect B** — `th[data-sort-key]` with page-local `::after` ⇅/↑/↓ CSS,
  copied three times with three separate sort implementations:
  `admin.leaf:207/427` (which contains *two* sorters for the same workers
  table — one DOM-based, one array-based for the poll repaint),
  `admin-users.leaf:83/118`, `assignment-submissions.leaf:125/142`.
- **Dialect C** — `th.sortable` + a `<span class="sort-icon">⇕` glyph
  swapped to ↑/↓, on `instructor-students.leaf:68/329` only.

Six sort implementations total. The quality gradient is inverted: the
**hand-rolled** copies have keyboard handling and `aria-sort`; the
**shared** component has neither ships-with-markup affordance beyond the
native button, sets no `aria-sort`, has no tie-break, and — decisive for
the polling pages — has **no re-apply API**, so a page that repaints its
tbody every 5 s cannot keep the user's sort. That missing API is *why* the
polling pages hand-rolled.

### F3. Poll repaints duplicate row markup in JS strings

Three pages poll every 5 s and rebuild their rows by string-concatenating
HTML in inline scripts, duplicating the Leaf markup wholesale:

| page | Leaf rows | JS twin | inline script size |
|---|---|---|---|
| `admin-users.leaf` | `:28-77` | `buildUserRow` `:242-281` | 183 lines |
| `instructor-students.leaf` | `:77-161` | `buildStudentRow` `:255-323` | 246 lines |
| `admin.leaf` (workers) | `:72-98` | `renderWorkers` `:379-422` | 430 lines |

The duplicated mass includes a complete `<details>` register-student
panel, role-`<select>` forms, delete-button SVGs, and `confirm()` message
literals — each present twice per page and able to drift independently.
This is the single largest contributor to the 1,968-line inline-script
ratchet.

The polls themselves also drift: users/students suppress refresh while the
filter or table has focus and send `X-Background-Refresh: 1`;
`admin-runner.leaf:167` sends **no headers at all**, so its poll resets the
idle-logout timer (see D-list).

### F4. Timestamps — split brain

`Public/relative-time.js` (`.js-relative-time[data-iso]`, absolute time in
the tooltip) serves 9 sites on 5 pages. Roughly 25 other timestamp columns
render raw server-formatted text — including Activity's "When", both
connected-agents tables' three date columns, and admin-mcp's "Created".
`relative-time.js` is loaded per-page by 6 templates rather than from
`base.leaf`; `assignments.leaf:309` loads it and calls
`applyRelativeTimes()` with **zero** `js-relative-time` nodes in the page
(dead include). The "offline if last-active > 5 min" rule is
re-implemented inline twice (`admin.leaf:392`, `admin-runner.leaf:145`).

There is no stated policy for which columns are relative and which are
absolute. (One is proposed in S8.)

### F5. Buttons — combo sprawl and label drift

161 classed `<button>`s + 46 button-styled `<a>`s resolve into ~20 class
combos. The systematic problems:

- **Primary form submits split** between `btn btn-primary` (~17 pages) and
  bare `btn` (5: `admin.leaf:53`, `admin-brightspace.leaf:76`,
  `admin-mcp.leaf:66`, `alerts.leaf:30`, `instructor-mcp.leaf:50`).
- **Three size modifiers doing one job**: `btn-compact`, `btn-tiny`,
  `action-btn-tight`.
- **Destructive row actions wear five different combos** (all including
  `action-danger`, differing in the size/icon modifiers).
- **Eight distinct "Save…" strings** ("Save", "Save changes",
  "Save settings", "Save webhook", "Save secret", "Save & verify",
  "Save & Validate", "Save and continue"), and bare "Save" renders at
  three visual weights depending on page.
- 7 intentionally-hidden unclassed buttons (`assignment-new.leaf:77-83`)
  are fine; no `<input type=submit>` anywhere (good).

### F6. Icons — 19 geometries, 11 duplicated inline

Every icon is a verbatim inline Feather-style SVG. The trash can exists in
**16 copies across 3 byte-level variants** (including the Leaf/JS twins on
the polling pages); the pencil in 11; refresh in 6; rewind in 5. One icon
breaks the set: `instructor-brightspace.leaf:179`'s push icon is
`fill`-based 16×16 (everything else is 24×24 stroked) and is also the one
icon-only button in the codebase missing an `aria-label`.

### F7. Destructive confirmation — 49 native `confirm()`s, unguarded

45 template occurrences (22 `onsubmit=`, 20 `onclick=`, 3 inline-script)
plus 4 in `Public/*.js`. Unlike `alert()`, `confirm()` has **no ratchet**.
Messages have drifted between copies of the same action ("Remove support
file …? Students who already use it will fail" vs "…Tests that read it
will fail"; two wordings for reset-notebook), and the polling pages carry
each message twice (Leaf + JS string). There is no seam at which a styled
confirm could ever be introduced — every call site owns its own
`window.confirm`.

### F8. Async feedback — six channels

A failed fetch surfaces, depending on page: (1) silently (empty catch —
the metric cards, the polls, `admin-runner`); (2) a role-less status span
(9 such spans, all driven by `ChickadeeUI.setStatus`, which sets no
ARIA); (3) a `role=status` span (workbench save, LEARN check); (4) an
injected `.form-error role=alert` banner (uploads, inplace forms); (5) a
full-page reload (section reorder, DnD); (6) a native `alert()`
(`suite-table.js` ×7, support-file delete ×4 — the same widget's *upload*
failure uses a status span while its *delete* failure alerts).

Flash banners: the `_flash` partial renders on only 9 pages. Other pages
either hand-roll flash markup (`admin-mcp.leaf:43`), misuse `.form-error`
as a page-state banner (`admin-mcp.leaf:13`, `admin-course.leaf:13`,
`instructor-enroll-csv.leaf:12`), or simply never render flash context.
`alerts.leaf:12` has a `.flash-neutral` missing its required
`role="status"`; the admin/instructor `.form-error` banners lack
`role="alert"` (the student-facing ones have it).

### F9. Page skeletons — archetype deviations and the page-CSS shadow vocabulary

Direct archetype violations (`ui-design.md` "Page archetypes"):

- `instructor-students.leaf:10-11` — page-local `.students-titlebar`
  duplicating `.page-titlebar`, plus an `<h1>` on a tabbed page restyled
  to `--text-lg` to *look* like an h2 (the explicit "don't restyle a
  heading to fake a level" rule).
- `instructor-activity.leaf:9/14` — `.section-block` (the suite editor's
  grouping) used as a generic section instead of `.page-section`;
  `.activity-intro` ≡ `.section-intro`; `.activity-filter` ≡ `.toolbar` +
  `.section-gap`.
- `assignments.leaf:8/12/75` — `<h1>` on a tabbed page, zero
  `.page-section`, `.section-block` misused for course sections.
- `instructor-brightspace.leaf` — a parallel private skeleton:
  `.bs-section`/`.bs-h2`/`.bs-tabbar`/`.bs-mapping-head` re-implement
  `.page-section`/h2/`.toolbar--end`/`.page-titlebar`.
- `admin-runner.leaf:6-9` — the only `/admin/*` page with neither the
  version banner + `_admin-tabs` nor a titlebar; page title is an `<h2>`,
  no `<h1>` exists; `.runner-header` ≈ the global `.editor-titlebar`.
- `admin-storage.leaf:9/22` — `.storage-bar`(`--end`) ≡
  `.page-titlebar`/`.toolbar--end`.
- `admin-users.leaf:8`, `admin-brightspace.leaf:8` — `.page-section` with
  no `<h2>`; `alerts.leaf:18/38/81` and `admin-runner.leaf:47/85` start
  sections at `<h3>`.
- `connected-agents.leaf` — matches no archetype (no tabs, no titlebar,
  no h1).

The page-`<style>` blocks collectively maintain a **shadow vocabulary** —
the same concept re-implemented under page-local names, which the
duplicate-selector guard cannot match because the *names* differ:

| concept | global owner | page-local shadows |
|---|---|---|
| title-left/actions-right row | `.page-titlebar` | 7 (`.students-titlebar`, `.runner-header`, `.storage-bar`, `.bs-mapping-head`, `.bs-tabbar`, `.activity-filter`, `.class-goal-row`) |
| action-button cluster | `.toolbar`, `.row-actions-tight` | **17 names** |
| page subtitle | `.page-subtitle` | 5 (`.student-subtitle` ≡ `.history-subtitle` byte-identical, `.history-student-id`, `.runner-subhead`, `.enroll-csv-course-name`) |
| intro / aside line | `.section-intro`, `.section-note` | 5 |
| muted hint text | `.text-muted`, `.card-meta`, `.fine-print` | **14 names** |
| flush / inline forms | `.form-flush`, `.inline-form` | 10 restatements |
| dl detail grid | `.detail-grid` | 2 (`.bs-status`, `.csv-result-list`) |
| card / callout | `.card`, `.notice-box` | 4 (incl. `workbench.leaf:81` ≡ `_notebook-body.leaf:61` byte-identical) |
| mono textarea | — (no owner yet) | 3 (`.guide-textarea`, `.enroll-csv-textarea`, `.mcp-token-area`) |
| status pill | `.tier`, `.chip` | `.learn-flag` (danger pill), `.bs-count-*` ≡ `.bs-test-*` (same colour pair twice in one file) |
| compact select | `.input-compact` | 5 near-identical selects |
| diagnostics-cards gap | — | 3 names; `.admin-diagnostics` is *applied* on `admin-storage.leaf:8` where its rule (defined in `admin.leaf`'s block) never loads |

Also: `course-student-submissions.leaf` duplicates its own 135-line row
block verbatim (`:24-158` vs `:167-301`), re-styles the global
`.ext-details` from a page block (`:332` — escapes the shadow guard only
because the global sheet never declares the bare selector), and its
`.action-panel` is the queued future `.popover-panel`;
`student-assignment-history.leaf` and `assignment-student-history.leaf`
are near-identical whole templates; `_assignment-table-head.leaf` has
exactly one consumer while `assignments.leaf` inlines a different thead
twice.

The `ui-design.md` migration queue is partially stale: the
`.submissions-table`/`.import-result-table` entry describes a
bottom-margin pair that is actually a bottom-margin vs **max-width** pair,
and the queue's five entries under-count the families above.

### F10. Popovers and modals — forked implementations

The set/clear popover family is forked: the *same* grade-override popover
is `.ext-panel` on `assignment-submissions.leaf:71` but `.action-panel` on
`course-student-submissions.leaf:131` — and `app.js`'s viewport-clamped
floating (built precisely because these panels clip against
`.results-table` overflow) binds **only** to `.action-panel`, so the
assignment-submissions variant can still clip near the table's bottom
edge. Two hand-rolled modal overlays exist (`test-editor-modal.js`,
`idle-logout.js`); only the second has a focus trap, and the first styles
its scrim via `style.cssText` with a raw `rgba()` that bypasses the
`--overlay-bg` token. No native `<dialog>` anywhere.

---

## Defects found incidentally (fix in S0, no design decisions needed)

- **D1** `connected-agents.leaf:48` — empty-state row hardcodes
  `colspan="7"`, but non-admins see a 6-column table (the "Authorized by"
  column is `#if(isAdmin)`).
- **D2** `admin-runner.leaf:167` — poll fetch sends no
  `X-Background-Refresh`, so viewing the runner dashboard resets the
  idle-logout timer forever; also no `document.hidden` guard.
- **D3** `instructor-brightspace.leaf:179` — icon-only push button has
  `title` but no `aria-label` (the only such gap; 48 of 49 icon buttons
  carry both).
- **D4** `alerts.leaf:12` — `.flash-neutral` static banner missing
  `role="status"`; the admin/instructor `.form-error` page banners
  (`admin-mcp.leaf:13`, `admin-course.leaf:13`,
  `instructor-enroll-csv.leaf:12`) missing `role="alert"`.
- **D5** `assignments.leaf:309/315` — dead `relative-time.js` include +
  `applyRelativeTimes()` call with no consuming nodes.
- **D6** `admin-storage.leaf:8` — `.admin-diagnostics` applied where its
  rule (page-local to `admin.leaf`) never loads; the cards render without
  the intended gap. Hoist the rule to `styles.css` under one name (see
  S7).
- **D7** `assignment-submissions.leaf:71` — grade-override popover missing
  the float/clamp treatment (`.ext-panel` vs `.action-panel` fork, F10).
- **D8** `instructor-students.leaf` poll repaint loses the LEARN-check
  flags' scroll/focus context is fine, but the *filter focus* guard exists
  while `admin.leaf`'s worker poll has no focus guard at all — align the
  three polls' guard sets (folded into S3).

---

## Implementation plan

Ten slices, each independently shippable and each ending with the
relevant ratchet lowered and `scripts/check-styles.sh` green. Sizes: S ≈
half a day, M ≈ 1–2 days, L ≈ 3–5 days of focused work including tests.
Recommended order: **S0 → S1 → S2 → S3 → S4 → S5 → S6 → S8 → S9, with S7
running as a page-by-page background track once S1–S6 exist** (S7's page
conversions *use* the components the earlier slices establish).

The house rule applies throughout: every consolidation gains a guard or
joins an existing ratchet, otherwise it will drift back — that is the
documented history of this codebase.

### S0 — Defect sweep (S)

Fix D1–D5 and D7 as written (D6 lands with S7's diagnostics-wrapper
hoist; D8 with S3). Zero design decisions; every fix is a line or two.
Include a render-test or `.mjs` assertion where one is cheap (D1: the
colspan follows the `isAdmin` flag; D2: assert headers on the poll fetch).

**Status: done.** D1–D5 and D7 landed in the S0 PR. D7 went slightly
further than parity: `app.js` now floats `.ext-panel` and `.action-panel`
alike, the binding is **delegated** (capture-phase `toggle` on the
document) so panels rebuilt by a poll repaint keep floating — which was a
latent break for instructor-students' register popovers after the first
5-second repaint — and a floated `.ext-panel` carries `--shadow-pop` via
`.is-floating` without changing its in-flow rendering. The banner-role
fixes follow the `_flash` split: action-failure banners got
`role="alert"`, persistent-state banners (`admin-mcp`'s endpoint-inactive
notice, `instructor-brightspace`'s reconnect notice) got `role="status"`.

### S1 — One list-filter pattern (M) — the prompting example

**Target state.** Every list filter is visually and semantically the same
control: `type="search"`, class `filter-input`, a visible
`.filter-label` ("Filter" / "Filter by person"), consistent
"Filter by …" placeholder microcopy, and the `--filter-width` custom
property. The *interaction* stays split by data locality — live where all
rows are in the DOM (users, students, submissions), GET-form where the
server caps the dataset (activity, audit) — but the two models share one
look, and the GET form keeps its Filter/Clear buttons as the only visible
difference.

**Changes.**

1. New `Public/list-filter.js` (~40 lines): binds every
   `input[data-list-filter]` to the table/tbody named by the attribute;
   whole-row `textContent` matching (the per-column variant on
   admin-users adds nothing a user can perceive — row text contains the
   same strings); exposes `ChickadeeListFilter.apply(input)` for poll
   repaints; toggles the `.empty` message where the page has one.
2. Delete the three inline `applyFilter` copies; instructor-students,
   admin-users, assignment-submissions adopt the attribute (lowers
   `INLINE_SCRIPT_BASELINE` ~40 lines).
3. Kill the `readonly onfocus` hack: extend `app.js`
   `suppressSpuriousAutofill()` to also cover form-less `.filter-input`
   elements, and drop `autocomplete="new-password"` on
   `admin-mcp.leaf:64` for plain `autocomplete="off"` — one suppression
   idiom.
4. `instructor-activity.leaf` and `admin-audit.leaf`: same control
   markup (`type=search`, `.filter-input`, visible label, `--filter-width`),
   keep `name=actor` + submit + Clear. Audit's extra action-`<select>`
   stays; it simply sits in the same `.toolbar`.
5. Placeholder microcopy convention documented in `ui-design.md`:
   "Filter by <fields>…" for live filters; the field list names what is
   actually matched.

**Guard.** `scripts/check-styles.sh` gains a one-line check: any
`filter-input` in a template must carry `data-list-filter` or sit in a
GET form (grep-able: `filter-input` without either attribute fails).

**Optional follow-up (S1b, decide after S1 ships).** A course-scoped
username `<datalist>` for the person-entry fields (activity actor, staff
add; audit actor could reuse the admin users list). Both consumers
already have roster visibility, so no new data exposure — but it needs a
small endpoint and is UX polish, not consistency; recommend deferring
until the unified control has been used for a term.

**Status: done.** `Public/list-filter.js` (unit-tested) plus
`.filter-group`/`.filter-label` landed; the three inline copies are gone
and guard 4c in `check-styles.sh` keeps both replaced idioms (a page-local
filter function, the readonly-until-focus hack in markup) from returning.
Convergence adopted the admin-users select-value matching everywhere — the
whole-row copies matched every row for "ta"/"instructor", because a role
`<select>`'s option labels are row text; the shared component's unit test
pins that rule. Two deliberate narrowings of the plan as written: the
autofill-suppression count went three → two, not one (`admin-mcp`'s
`autocomplete="new-password"` stays — the right tool for a real form field
that must never be offered saved credentials; the component owns the
form-less-filter case), and the GET-form inputs keep a plain
`autocomplete="off"` since they sit inside real forms. Visual-regression
baselines regenerated for instructor-students (the filter row wraps as a
label+input unit) and admin-users (visible label).

### S2 — One sortable table (M)

**Target state.** `Public/sortable-table.js` is the only sort
implementation; the `th > button.sort-header` convention is the only
markup; the `::after`-arrow CSS in the global sheet is the only
affordance.

**Changes.**

1. Upgrade the shared component to best-of-breed from the hand-rolled
   copies: set `aria-sort` on the active `th` (keyboard comes free —
   headers are real `<button>`s); `Intl.Collator(undefined,
   {numeric, sensitivity:'base'})`; optional `data-sort-tiebreak="<col>"`
   on the table; and the missing piece — remember the active sort per
   table and expose `ChickadeeSortableTable.apply(table)` so a poll
   repaint can restore it.
2. Migrate dialect B (admin ×2, admin-users, assignment-submissions) and
   dialect C (instructor-students): thead swaps to `button.sort-header`,
   delete the five page-local sorters (~180 inline lines) and the three
   copied `::after` CSS triads + students' `.sort-icon` block (~60 page
   style lines). `admin.leaf`'s second array-sorter dies with it (the
   repaint calls `apply`).
3. Default-sort attribute (`data-sort-initial="col:desc"`) so
   instructor-students keeps its last-seen-desc default and admin-users
   its current default, without page JS.

**Guard.** Extend `Tests/BrowserRunnerJSTests` with a unit test for the
component (sort types, tie-break, re-apply). A grep in `check-styles.sh`
forbids `data-sort-key`/`.sort-icon` reappearing in templates.

**Visual delta.** Students' ⇕ glyphs become the standard header buttons —
`instructor-students` and `admin-users` are both in
`Tools/visual-regression/pages.mjs`, so regenerate baselines in the same
PR.

**Status: done.** All six tables (admin workers + courses, admin-users,
assignment-submissions, instructor-students) now run
`Public/sortable-table.js`; the five page-local sorters and all three
affordance dialects are gone. The upgrade absorbed what each copy had
learned — collator comparison, `<select>`-value cells, `data-iso` doubling
as the sort value, "12/15" sorting as 12, the `-1` duration sentinel,
named tie-breaks — and added the two pieces none could share:
`data-sort-initial="<key>:desc"` (a load-time sort declared in markup, so
a page needs no script to open on "newest first") and `apply(table)` (the
missing re-apply API that was the *reason* the polling pages hand-rolled).
Keyboard support stopped being per-page code and became a real `<button>`.
Column identity is by `data-sort-key`, not index, so conditionally-rendered
columns cannot misalign a tie-break. Guard 4c grew an S2 clause covering
all three regressions: a page-local sorter, a page-local glyph, and a
`data-sort-type` th with no `.sort-header` button (decorative markup that
sorts nothing). Ratchets: `INLINE_SCRIPT_BASELINE` 1934 → 1548 (−386 lines,
the largest single drop so far), `PAGE_STYLE_BASELINE` 902 → 842. One
render test asserted a deleted JS call string and now asserts the
declarative attribute instead — a better test, pinning the contract rather
than the implementation.

### S3 — Poll repaints without JS row builders (L)

**Target state.** A polled table's rows exist in exactly one place — a
Leaf row partial — rendered server-side both for the full page and for
the poll response. The JS twins (`buildUserRow`, `buildStudentRow`,
`renderWorkers`) are deleted.

**Changes.**

1. Extract row partials: `_user-rows.leaf`, `_student-rows.leaf`,
   `_worker-rows.leaf`, each consumed by its page template *and* by a
   fragment rendering of the existing `*-data` endpoints (an
   `Accept: text/html` or `?fragment=rows` branch returning just the
   rendered rows; JSON behaviour unchanged for any other consumer).
2. Page JS becomes: fetch fragment → `tbody.innerHTML = html` →
   `ChickadeeRelativeTime.applyRelativeTimes(tbody)` →
   `ChickadeeSortableTable.apply(table)` →
   `ChickadeeListFilter.apply(input)` → page-specific decorations
   (LEARN flags). This is the same "server renders, client swaps"
   pattern `ChickadeeUI.swapHalf` already established for the workbench.
3. Align the three polls' guard sets (D8): skip on `document.hidden`,
   focus-within-table, focus-in-filter; always send
   `X-Background-Refresh: 1` + `Accept`.
4. The duplicated `confirm()` literals, register-panel markup, role
   selects and SVGs inside the JS builders disappear as a side effect.

**Ratchet effect.** The three biggest inline scripts shrink by roughly
half or more (~350–450 lines off `INLINE_SCRIPT_BASELINE` — the largest
single drop available anywhere).

**Tests.** Render tests for the three fragments (they are just routes);
existing page render tests unchanged. CSRF note: the fragment carries the
same `#csrfFormField()` forms the page does, so token freshness matches
today's behaviour (the JS builders already inlined the meta token).

**Status: done.** All three polls now swap in server-rendered rows from the
same Leaf partials the pages use (`_student-rows`, `_user-rows`,
`_worker-rows`), reached by `?fragment=rows` on the existing endpoints;
the JSON representation is untouched for every other consumer. The three
JS row builders are gone, and with them the second copies of the role
`<select>` forms, the CSRF fields, the trash/pencil SVGs and an entire
register-pending-student popover.

The polling itself turned out to be shared too, so it is one component
(`Public/table-poll.js`, opted into with `data-poll-url`) rather than three
rewrites — which is what made D8 disappear rather than be fixed: the guard
set (hidden tab, focus inside the table, focus in the filter) and the
`X-Background-Refresh` header are now properties of the mechanism, not of
whichever page remembered them. Page-specific work rides a
`chickadee:table-repaint` event, so the roster's count and LEARN badges and
the dashboard's Max Load summary stay page code without forking the poll.

Two things fell out of doing it. **`admin-users.leaf` now has no inline
script at all** (330 → 60 lines). And the runner "offline" rule moved to
the server (`RunnerStaleness`, with `ChickadeeRelativeTime.isStale` as its
client half), which fixed a real defect neither the audit nor the plan had
spotted: the badge was computed only *during a poll*, so a freshly loaded
dashboard showed no offline badges until the first tick — the badge marked
"you have waited five seconds", not "this runner is down".

Also caught here: S2 had left a dangling `refreshWorkers()` call in
`admin.leaf` — a ReferenceError every 5 s on the admin dashboard, invisible
to ESLint because it lives in an inline template script. That is precisely
the blind spot the inline-script ratchet exists to shrink, and S3 removes
the last of that page's polling code. Fixed here and called out on the S2
PR.

### S4 — One icon set (M)

**Target state.** `Public/icons.svg` — a single same-origin SVG sprite of
the 19 Feather-style geometries (`<symbol id="trash">…`) — and one
`.icon` class in `styles.css`. Templates use
`<svg class="icon" aria-hidden="true"><use href="/icons.svg?v=#appVersion()#trash"/></svg>`;
JS builds the same string via `ChickadeeUI.icon(name)` (which S3 mostly
obsoletes, but the suite/achievements/inputs editors still build icons).

**Changes.** Replace ~60 inline SVG sites; redraw the one off-set icon
(brightspace push) in the house 24×24 stroked style. The three
byte-variants of the trash can collapse to one symbol.

**Guard.** New shrink-only ratchet in `check-styles.sh`:
`INLINE_SVG_BASELINE` counting `<svg` occurrences in templates that are
not `class="icon"` uses (start at the residual count, ratchet to ~0).

**Status: done.** 58 call sites now reference 17 `<symbol>`s in
`Resources/Views/_icons.leaf`. Two deviations from the plan, both
deliberate. The sprite is **inlined by `base.leaf`, not fetched** as
`/icons.svg`: an external sprite is one more request that can fail, and its
failure mode is an icon-only button rendering as an empty box — same-document
`<use>` cannot fail that way, needs no CSP allowance, and costs no round
trip. And the guard is not a ratchet but an **absolute rule**: geometry
(`<path d=`, `<polyline points=`, `<circle cx=`) may appear only in the
sprite file, which was reachable in one pass and is a stronger invariant
than a shrinking count.

The sprite was **generated from the geometries it replaces** rather than
hand-transcribed — an early hand-typed mapping was quietly wrong in several
entries, and a mis-copied path is invisible in review — so every symbol is
byte-identical to the shape it replaced. The exception is the LEARN push
icon, the one glyph from a foreign set (filled, 16×16, visibly heavier
than its neighbours), redrawn in the house 24×24 stroked style. Size moved
to `1em` so a glyph tracks the text of the button it sits in, replacing
hardcoded `width="13"`. Visual regression is pixel-identical across both
schemes, which is the evidence the substitution was faithful.

### S5 — One confirmation seam (S/M)

**Target state.** No inline `onclick`/`onsubmit` confirm handlers. A
form or button that needs confirmation declares
`data-confirm="message"`; one delegated listener in `app.js` intercepts
submit/click and calls `window.confirm` today. Every future improvement
(a styled `<dialog>`, "type the course code to delete") lands in that
one listener.

**Changes.** Mechanical conversion of the 45 template sites; while
converting, unify the drifted wordings (one message per action — the
support-file and reset-notebook pairs pick one string each). The 4
`Public/*.js` sites route through `ChickadeeUI.confirmAction(msg)`
wrapping the same seam. Buttons using `formaction` keep working (the
listener reads the submitter).

**Guard.** New shrink-only ratchet: inline `confirm(` in templates,
baseline 45 → 0 in this slice, then the guard forbids reintroduction.
This mirrors exactly how `alert()` is already ratcheted.

**Status: done.** All 43 template attributes are now `data-confirm`, and the
seven JS call sites route through `ChickadeeUI.confirmAction`. Because the
conversion reached zero in one pass, the guard is an **absolute rule**
rather than a ratchet: a native `confirm(` outside the seam fails CI.

Clicks are intercepted in the **capture** phase, which is a small upgrade
on what the inline attributes did: a cancelled delete now also stops the
handlers layered around the button (row-click navigation, popover toggles),
where `return false` from an inline `onclick` only stopped the default.
Submits stay in the bubble phase, where they run before
`inplace-forms.js`'s listener — which already bails on `defaultPrevented`,
so a cancelled submit stays cancelled inside the workbench too. A submitter
carrying its own question (the `formaction` "Clear"/"Remove" buttons) asks
that question and not the form's.

Two drifted wordings were unified while converting, as planned: the
reset-notebook pair keeps the longer sentence (it states that the student
gets the fresh starter automatically — the fact an instructor needs before
clicking), and the remove-support-file pair keeps "Tests that read it will
fail", which is true on both pages where the edit page's "Students who
already use it" was not.

Verified in a real browser rather than by inspection, since a broken seam
fails *open* — every destructive action would go through unasked:
cancelling blocks the POST, accepting sends it, and a `formaction`
submitter asks its own question and posts to its own action.

One process note worth keeping: the first version of the guard failed on
its own documentation, because the comment quoted the idiom it forbids.
That is the `#1266` Leaf-comment lesson in a new place — **a scanner cannot
tell markup from prose about markup** — and the fix is the same one that
finding produced: describe the forbidden syntax, do not quote it.

### S6 — Button and label grammar (M)

**Target state,** codified in `ui-design.md`'s component vocabulary:

- Primary form submit: `btn btn-primary` — always, including the 5
  plain-`btn` stragglers.
- Secondary / navigation: `btn`.
- In-table / inline action: `btn action-btn`; destructive adds
  `action-danger`; icon-only adds `action-btn-icon` (+ `aria-label`).
- **One** size modifier survives. Recommendation: `btn-compact` (already
  emitted by the shared accordion); fold `btn-tiny` and
  `action-btn-tight` into it, measuring the padding deltas and picking
  the compact values once.
- Save-label microcopy: bare "Save" unless the same view contains two
  save targets (then "Save <thing>"); "Save & Validate" stays as the
  deliberate assignment-editor exception. Buttons always declare
  `type=`.

**Changes.** Template edits + a `styles.css` pass to alias-then-remove
the folded modifiers. Visual deltas are minor but real — regenerate
affected visual-regression baselines.

**Guard.** `check-class-resolution.sh` already fails removed classes;
add the retired modifier names to a forbidden-list grep so they cannot
return.

### S7 — Page skeletons and the shadow vocabulary (L, page-by-page track)

One PR per page (or pair), each: convert to its archetype, replace
page-local shadow classes with the global vocabulary, and lower
`PAGE_STYLE_BASELINE` by the measured amount. Order by payoff:

1. **instructor-students** — `.students-titlebar` → `.page-titlebar`
   (+`.toolbar`), `<h1>` → `<h2>`-anchored sections, pending-row rules
   collapse to one class, `.learn-flag` → new global `.chip-danger`
   (added to the vocabulary; `.bs-count-err`/`.bs-test-err` adopt it
   later), `.form-flush`/`.inline-form` adoption. (S1–S3 will already
   have emptied most of its inline script.)
2. **instructor-activity** — `.section-block` → `.page-section`,
   `.activity-intro` → `.section-intro`, `.activity-filter` → `.toolbar
   section-gap` (S1 does the input itself), timestamp column → S8
   treatment, column-width classes stay page-local (genuinely
   page-specific values are the sanctioned use of a page block).
3. **instructor-brightspace + admin-brightspace** — dissolve the private
   skeleton (`.bs-section`/`.bs-h2`/`.bs-tabbar`/`.bs-mapping-head` →
   `.page-section`/h2/`.toolbar--end`/`.page-titlebar`), `.bs-status` →
   `.detail-grid`, the two green/red count-pill pairs → `.chip`/
   `.chip-danger`, notes → `.section-note`. The two `.bs-*` namespaces
   share no selector names — this is concept-level, not selector-level,
   dedup.
4. **admin-storage + admin-runner** — `.storage-bar` → `.page-titlebar`/
   `.toolbar--end`; runner gets the admin version banner + `_admin-tabs`
   like every other `/admin/*` page, `.runner-header` → `.page-titlebar`,
   h3 → h2 under the tab archetype; hoist the diagnostics-wrapper gap to
   one global name (fixes D6).
5. **course-student-submissions** — extract the 135-line duplicated row
   block into one Leaf partial (the honest-copy test from the Leaf
   decomposition review does not apply here — the two blocks are
   verbatim); `.action-panel` + `.ext-details{position:relative}` →
   global `.popover-panel` bound by `app.js` (completing D7 from the
   other side); `.student-subtitle` → `.page-subtitle`.
6. **assignments** — h1 → tabbed-archetype h2 sections, `.section-block`
   misuse → `.page-section`, diagnostics wrapper → shared name; evaluate
   folding its inline thead pair into `_assignment-table-head` (its
   columns genuinely differ from index.leaf's — if so, they are honest
   copies and stay).
7. **Long tail** — subtitle family, muted-hint family (→ `.fine-print`/
   `.card-meta`/`.text-muted`), mono-textarea family (→ one new
   `.textarea-mono` vocabulary entry), `.csv-result-list` →
   `.detail-grid`, callout re-implementations → `.card`/`.notice-box`
   (incl. the byte-identical workbench/notebook small-screen notice —
   hoist once), compact selects → `.input-compact` extension,
   `student-assignment-history` vs `assignment-student-history` template
   merge (parameterize the one differing header), empty-state
   normalization (`.empty` outside the table; in-tbody rows only where a
   sortable table is not involved — admin-mcp's two currently sort their
   own empty rows).

Each page PR regenerates its visual-regression baseline if listed in
`pages.mjs`, and updates `ui-design.md`'s migration queue (which this
document supersedes as the inventory of record — the queue keeps only
what remains).

### S8 — Timestamp policy (S)

**Policy** (added to `ui-design.md`): human-activity times ("last seen",
"authorized", "fired", "completed", activity feeds) render relative via
`js-relative-time` with the absolute value in the tooltip;
compliance/forensic times (audit log, retention dates) render absolute
in `--font-mono`, deliberately. **Changes:** load `relative-time.js`
from `base.leaf` (57 lines, ends the per-page includes and the dead
include D5); convert Activity "When", connected-agents/admin-mcp date
columns, brightspace last-sync, slip-day dates; hoist the
offline-threshold rule into `relative-time.js`
(`ChickadeeRelativeTime.isStale(iso, ms)`) for the two inline copies.

### S9 — Feedback channels (M)

**Target state:** two channels. Passive/progress feedback is a
`role="status"` span driven by `ChickadeeUI.setStatus`; failures that
block the user's action are a `.form-error role="alert"` banner (the
`inplace-forms.js` injection pattern). Silent catches remain correct
*only* for background polls whose next tick self-heals.

**Changes.** Add `role="status"` to the 9 role-less status spans (markup,
not JS); replace `suite-table.js`'s 7 alerts and the support-file delete
alerts with the banner/status patterns (drops `JS_ALERT_BASELINE` 7 → ~0
and `ALERT_BASELINE` 4 → 0); `test-editor-modal.js` scrim moves off
`style.cssText` onto classes (lowers `JS_STYLE_DECISION_BASELINE`).

**Flash decision (recommendation: yes).** Render `_flash` once from
`base.leaf` (immediately above the content slot) instead of per-page
includes: every redirect-set flash then renders everywhere, the 9
per-page includes disappear, and hand-rolled banners (`admin-mcp.leaf:43`
success, the `.form-error`-as-page-banner sites) convert to real flash
context or `.flash-warning` statics. The token-display banner on
admin-mcp keeps its custom body (it renders a copyable `<code>` value —
genuinely not a text flash). Visual-regression baselines cover the
layout shift risk on the captured pages.

---

## Decisions taken vs deferred

| decision | taken in this plan | deferred |
|---|---|---|
| Live vs server-side filtering | Keep split by data locality; unify the control's look/labels (S1) | Making activity/audit live would require uncapping their queries — not worth it |
| Person typeahead | — | S1b, after the unified control has real usage |
| Confirmation UX | One `data-confirm` seam, native `confirm()` behind it (S5) | Styled `<dialog>` confirm, typed-name deletes |
| Size modifiers | Fold to `btn-compact` (S6) | — |
| Flash placement | `base.leaf`-rendered `_flash` (S9) | — |
| Modal implementation | Token/class fixes only (S9) | Converging the two overlays on native `<dialog>` |
| Sortable markup | `th > button.sort-header` everywhere (S2) | — |

## What is deliberately not in scope

- The **workbench/notebook editor internals** (`suite-table.js`'s editor
  logic, `notebook.js`) beyond the named seams (alerts, icons, the
  byte-identical small-screen notice). The #1266/#1269 decomposition
  already owns that surface's structure.
- The **two honest copies** of the assignment-files table
  (`assignment-new` vs `_assignment-edit-body`) — structurally different
  rows, per the Leaf decomposition review.
- `notebook.js`'s in-browser results table — its columns intentionally
  differ from `submission.leaf` (live grading output vs stored results);
  it adopts the icon sprite and nothing else.
- Anything behind the grading contract, MCP surface, or JupyterLite
  vendoring.

## Tracking

Suggested issue structure: one epic ("UI widget-layer consolidation"),
one issue per slice S0–S9 (S7 as a checklist issue with per-page boxes).
Each slice PR: lowers its ratchet(s) in the same PR, runs
`scripts/check-styles.sh` + affected render tests + the JS gate
(`scripts/eslint.sh`, `node --test Tests/BrowserRunnerJSTests/*.mjs`),
and regenerates visual-regression baselines when a captured page's look
changes. This document is updated per slice with a "Status" line per
finding, in the manner of `multi-language-audit.md`, so a later reader
does not chase a fixed defect.
