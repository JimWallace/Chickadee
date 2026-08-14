# UI Design Principles

How Chickadee's web UI stays visually consistent, and how that consistency is
*enforced* rather than remembered.  The web UI is Leaf templates + one global
stylesheet (`Public/styles.css`); the render tests only prove pages render, so
every rule here is backed by a static guard that runs in the `format-lint` CI
job.  If a rule matters and has no guard, the history of this codebase says it
will drift — 26 distinct font sizes and 18 distinct border radii had
accumulated before the token pass consolidated them.

## The one-line rule

**Don't invent a value; pick a token.**  Colours, font sizes, and corner radii
all come from named scales in `Public/styles.css`.  If none of the existing
steps looks right, the fix is a conversation about the scale, not a new
literal in a rule body.

## Tokens

All tokens are CSS custom properties declared in the `:root` block of
`Public/styles.css`, with a `prefers-color-scheme: dark` mirror for colours.

### Colour

- **Raw colour literals — `#hex`, `rgb()`/`rgba()`, `hsl()`/`hsla()` — may
  only appear as the value of a `--token:` declaration in
  `Public/styles.css`** — never in a rule body, and never in a page `<style>`
  block.  Everything else uses `var(--x)`.  This is what makes dark mode
  work: a hardcoded `#d4edda` success banner is invisible-text-on-dark
  waiting to happen (that exact bug is why `--success-fg` / `--danger-fg`
  exist).
- Prefer the **semantic** tokens (`--success-bg`/`--success-fg`,
  `--danger-bg`/`--danger-fg`, `--warning-bg`, `--open-bg`/`--open-fg`,
  `--accent-bg`/`--accent-fg`, `--muted`, `--text-secondary`, `--border`,
  `--surface`) over raw palette entries (`--gray-500`, `--red`) — semantic
  tokens carry their own dark-mode values and keep state colours consistent
  across pages.
- Adding a colour means adding a token **pair**: light value in `:root`,
  dark value in the `prefers-color-scheme: dark` block (or an explanatory
  comment when the light value is correct in both, e.g. `--nav-bg`).

### Type scale

Eight steps.  Pick the nearest; do not add a step for a one-off.

| Token | Value | Use for |
|-------|-------|---------|
| `--text-2xs` | .72rem | fine print — table meta, chart labels |
| `--text-xs` | .75rem | badges, pills, column hints |
| `--text-sm` | .8rem | dense table text, secondary UI |
| `--text-base` | .875rem | standard control / body-copy text |
| `--text-md` | 1rem | emphasized body, large inputs |
| `--text-lg` | 1.05rem | card titles, nav brand |
| `--text-xl` | 1.2rem | section headings |
| `--text-2xl` | 1.4rem | page headings |

`em` values and `inherit` are also allowed — `em` expresses *relative* sizing
inside a component (`code` at `.9em`, a display glyph at `5em`) and is the
right tool when the size should track the parent, not the scale.

### Radius scale

| Token | Value | Use for |
|-------|-------|---------|
| `--radius-sm` | .25rem | chips, code spans, small controls |
| `--radius-md` | .4rem | buttons, inputs, menu items |
| `--radius-lg` | .5rem | cards, tables, modals, callouts |
| `--radius-full` | 999px | pills, round icon buttons |

`0`, `50%` (circles), and multi-value corner shorthands are also allowed.

### Spacing lattice

Spacing (`padding` / `margin` / `gap`) is a **ratchet, not a scale**: every
rem component must be one of the 26 steps allowlisted in
`scripts/check-design-tokens.sh` (`SPACING_STEPS`).  The list only shrinks —
never add a step for a one-off; pick the nearest existing one.  For **new**
code prefer the core ladder:

- `.25rem` / `.5rem` / `.75rem` / `1rem` / `1.25rem` / `1.5rem` / `2rem`
  for component and layout spacing;
- `.1rem`–`.45rem` (in .05 increments already on the lattice) only for
  tight chrome — badge padding, icon gaps.

`0`, `auto`, percentages, `1px` hairlines, and `calc()`/`clamp()` are
outside the rule.

### Shadow

One elevation: `--shadow-pop`, used by every pop-out menu, dropdown, and
floating panel.  It carries a stronger alpha in dark mode (a `.15` black
shadow is invisible on a dark surface).  Don't hand-roll `box-shadow`
values — if a second elevation level is ever genuinely needed, add a
second token.

### Other tokens

`--font-mono` is the one monospace stack — never restate
`ui-monospace, SFMono-Regular, …` (or bare `monospace`) inline.
`--nav-fg` / `--nav-fg-muted` are the white-alpha nav foregrounds (the nav
is black in both schemes).

## Page archetypes

Every page extends `base.leaf` (nav, colour bar, course tabs, `main.main`)
and then follows ONE of these skeletons.  Don't invent an eighth shape —
pick the archetype, and reuse its components:

| Archetype | Skeleton | Examples |
|-----------|----------|----------|
| **Admin tabbed** | `.admin-version-banner` → the `_admin-tabs` partial → `.page-section` blocks, each opening with an `<h2>` | admin, admin-users, alerts |
| **Instructor tabbed** | the `_instructor-tabs` partial → `.page-section` blocks | assignments, instructor-students, instructor-mcp |
| **Titlebar page** | `.page-titlebar` (`<h1>` left, actions right) → optional `.page-subtitle` → content | admin-course, admin-user, assignment-submissions |
| **Plain student page** | `<h1>` → content | index, submit, enroll, account |
| **Auth box** | `.auth-box` centred card | login, register, oauth-consent |
| **Body-partial shim** | `#extend` of a shared body partial, no markup of its own | assignment-edit, notebook |
| **Full-bleed app** | `fullBleed` context flag; owns the viewport | workbench |

Anatomy rules that hold across archetypes:

- **Flash banners render through the `_flash` partial** — never hand-rolled.
  It emits `.flash-success role="status"` / `.flash-error role="alert"` from
  the `flashSuccess` / `flashError` / `notice` context values.  Static state
  banners use `.flash-neutral` / `.flash-warning` with `role="status"`.
- **Tab bars are the `_admin-tabs` / `_instructor-tabs` partials.**  The
  active tab rides `activeAdminTab` / `activeInstructorTab`.
- **Headings are structural:** tabbed pages start their sections at `<h2>`
  (the tab bar is the page title); every other page has exactly one `<h1>`.
  Don't restyle a heading to fake a different level.
- **`.page-section` is the one generic section wrapper** (heading + content).
  `.section-block` is the suite editor's per-test-section grouping and
  `.submission-section-block` the results grouping — not general-purpose.
- Dense/wide tables wrap in `.table-scroll`.

## Component vocabulary

Reuse before you restyle — this catalog is closed in the sense that a new
page must be assembled from it, and a genuinely new pattern must be ADDED to
it (and to this list) rather than approximated privately in a page block.
The audit that produced this rule found sixteen page-local names for "a row
of action buttons" and four pill implementations; the page-style ratchet
(below) now makes the private copy the expensive option.

- **Buttons** — one grammar (UI audit S6):
  - a form's primary submit is `btn btn-primary`; secondary actions beside it
    are `btn`;
  - an action inside a table row or toolbar is `btn action-btn`, `+ action-danger`
    when destructive, `+ action-btn-icon` when icon-only (which then needs an
    `aria-label`, and its icon comes from the sprite);
  - **two sizes only**: default and `btn-compact` for `.btn`;
    `action-btn-icon` is the one narrow variant of `.action-btn`.
  - class order is `btn action-btn action-btn-icon action-danger`.
  - Every `<button>` declares `type=` — an omitted type submits, which is the
    wrong default for a JS-driven control.
- **`.form`**, `.form--wide`, `.form-input`, `.form-error`, `.form-flush`,
  `.inline-form` — forms and the inline error banner (never native
  `alert()`).
- **`_flash` partial** + `.flash-*` — see page anatomy above.
- **`.page-titlebar`** (+ `--baseline`), **`.page-subtitle`** — the page
  header row and its secondary line.  Cluster multiple left/right items
  inside with `.toolbar`.
- **`.page-section`**, **`.section-intro`**, **`.section-note`** — section
  wrapper, its lead-in paragraph, its italic aside.
- **`.toolbar`** (+ `--end`), `.row-actions-tight` — horizontal control
  clusters; filter rows are `.toolbar .toolbar--end .section-gap`.
- **`.filter-group`** — the one list-filter control: a `.filter-label` +
  `.filter-input[type=search]` pair that wraps as a unit.  Every
  `.filter-input` sits in one, GET-form filters included, and every one is
  `--filter-width` wide — that custom property is declared once in `:root`
  and is **not** a per-page dial (five boxes once came in three sizes).
  A page declares only the wrapper, the classes, `data-list-filter` naming
  the table, and `data-list-filter-empty` wording its no-match message;
  `Public/list-filter.js` derives the rest — which columns are searchable
  (the ones the table declares sortable, so the Actions column's buttons and
  panels are not matched), term matching, the `role="status"` result count,
  the no-match message, Escape-to-clear, `aria-controls`, and autofill
  suppression for *every* `.filter-input`, so a filter never carries
  `autocomplete` in markup.  Never re-implement any of it in a page script.
  Server-side GET filters (activity, audit) wear the same dress plus
  Filter/Clear buttons, and load the same script for the suppression and
  Escape.  Placeholder microcopy on live filters: "Filter by
  &lt;matched fields&gt;…"; `data-list-filter-empty` names the row type
  ("No students match this filter.").  The markup contract is asserted by
  `Tests/APITests/ListFilterMarkupTests.swift`, which walks the tags rather
  than searching the document.
- **`.field-inline`**, `.field-stack` (+ `--grow`, `--narrow`), `.field-note`
  (+ `--muted`), `.field-help`, `.input-compact`, `.editor-input`,
  `.select-xs` — form-field layout, hints, and the compact control sizes.
- **`.cell-input`** (+ `--with-check`), `.input-mono`, `.points-input`,
  `.suite-name-input` — form controls embedded in dense table cells (inputs
  panels, case tables, suite rows).  Server-rendered rows and JS row
  builders share these, so the two renderings of one row cannot drift.
- **Value-state cues** — `.input-expression` (green per-student tint),
  `.input-attention` (amber), `.input-invalid` (red), `.input-computed`
  (muted), `.input-ref-ok` / `.input-ref-broken` (italic green/red `$name`
  refs).  Editors toggle these classes; they never write the colours.
- **`.modal-overlay`**, `.modal-card`, `.modal-head/-body/-foot`,
  `.modal-title/-close/-status/-desc` — the one modal shell
  (test-editor-modal.js).  `hidden` does the showing and hiding.
- **`.editor-stack`**, `.editor-cm-mount`, `.cell-stack`, `.cell-title`,
  `.cell-actions` — editor-built layout: vertical field stacks, the
  CodeMirror host, and table-cell title/meta and action clusters.
- **`.results-table`** (+ `.table-scroll`), **`.sortable-table`** — the one
  column sort (`Public/sortable-table.js`).  Markup:
  `<th data-sort-key="…" data-sort-type="text|number|date|duration">` wrapping
  `<button class="sort-header">`; the cell's sort value is `data-sort-value`,
  else `data-iso`, else a contained `<select>`'s value, else its text.
  `data-sort-initial="<key>:desc"` declares the load-time sort and
  `data-sort-tiebreak="<key>"` the tie-break; a page that repaints rows calls
  `ChickadeeSortableTable.apply(table)`.  Never hand-roll a sorter or a sort
  glyph — the guard fails on both.
- **`.diagnostics-cards`** + `.diagnostic-card/-label/-value` — stat tiles.
- **`.chip`**, `.chip-row` — neutral tags.  `.tier` + `.tier-*` — status
  badges (defined variants only: open/closed/extended/preview/unpublished).
- **`.text-muted`**, `.card-meta`, `.fine-print` — muted text.
  `.text-error` / `.text-ok` / `.text-quiet` — status-line colours
  (`ChickadeeUI.setStatus` toggles them; nothing writes `el.style.color`).
- **`.ext-details`/`.ext-panel`/`.ext-field-*`** — inline set/clear popover
  forms.
- **`.card`**, `.notice-box`, `.error-box` — surfaces and callouts.

If two pages need the same rule, it belongs in `Public/styles.css`, not
copied into both `<style>` blocks — the duplicate-selector guard fails CI on
copies, and the page-style ratchet fails CI on growth.

## Timestamps

Two renderings, chosen by what the reader is asking (UI audit S8):

- **Human activity** — "last seen", "authorized", "last used", "fired",
  "completed", an activity feed — renders **relative** via
  `<td class="js-relative-time" data-iso="…">`, which
  `Public/relative-time.js` (loaded from `base.leaf`) rewrites to "3 hours
  ago" and gives an absolute `title`.  The reader wants recency, and a
  relative value answers that at a glance.  A **countdown** (a token's
  expiry) is the same case: "in 3 days" beats a date.
- **Forensic or compliance** times — the audit log, retention dates —
  render **absolute**, in `--font-mono`, deliberately.  Here the exact
  instant *is* the content, and "2 months ago" would destroy it.

The server-formatted string stays in the cell as the no-JS fallback, so a
column degrades to an absolute date rather than to nothing.  Staleness
questions ("is this runner offline?") use
`ChickadeeRelativeTime.isStale(iso)`, whose threshold is the client half of
`RunnerStaleness` — never a hand-written `Date.now() - t > …` comparison.

## Class names must resolve

A class name assigned in a template or in first-party `Public/*.js` must
resolve to a stylesheet rule — `scripts/check-class-resolution.sh` fails CI
otherwise.  A name that resolves to nothing is invisible to every other
check, and that class of bug shipped repeatedly: drag-and-drop indicators
assigned but never styled, `.btn-secondary` / `.badge-*` / `.tier-public`
variants that exist nowhere and silently rendered as unstyled text.

- **Behaviour-only hooks take the `js-` prefix** (`js-relative-time` is the
  house example) — the guard exempts them.  Pre-existing hooks are listed in
  `scripts/class-resolution-allowlist.txt`, which only shrinks.
- **Leaf-interpolated class families** (`status-#{…}`-style names built from
  enum values) are outside the grep's reach; they are pinned by
  `Tests/APITests/StatusClassStylesheetTests.swift`, which iterates the enum
  (`CaseIterable`) and asserts each minted selector exists.  A new
  interpolated family needs the same treatment.
- A class name a cross-page script depends on (e.g. `.error-message`, which
  `chickadee-ui.js` scrapes out of fetch bodies) lives in the global sheet
  with a comment naming the contract — never in a page block where a rename
  looks safe.

## Page-local scripts

Page behaviour belongs in a **`Public/*.js` file**, loaded with
`<script src>` — there it is ESLint-checked and unit-testable
(`Tests/BrowserRunnerJSTests`).  Inline `<script>` blocks in templates are
invisible to every tool (ESLint can't parse Leaf-interpolated JS), so the
rule is **absolute** (guard 3b in `scripts/check-styles.sh`): no template
may open a multi-line `<script>` body.  The 2026-08 conversion moved every
page's blocks out; the one deliberate holdout is `base.leaf`'s
multipart-CSRF interceptor, held by its own shrink-only line ratchet
(`INLINE_SCRIPT_BASELINE`).

The extraction pattern: the template carries page data — `data-*`
attributes or a **single-line** `<script type="application/json">` island —
and a per-page wiring file reads it (`assignment-edit-page.js` /
`assignment-new-page.js` are the worked examples: shared editor modules,
per-page URL builders).

### JS does not make styling decisions

JavaScript **toggles classes** (or the `hidden` attribute) and, when a value
is genuinely runtime-computed, **sets a CSS custom property**
(`workbench.js`'s `--wb-left-width` is the pattern).  It does not write
colours, sizes, spacing, or `style="…"` strings — those bypass every token
guard, and the audit found the type and radius scales 100 % bypassed in JS,
including an injected stylesheet with its own private dark-mode block
(`idle-logout.js`, since moved into `styles.css`).  Runtime-computed
*geometry* (popover positioning in `app.js`) is the one sanctioned use of
direct `.style` writes.

Two idioms reached zero in the 2026-08 editor conversion and are now
**absolute rules** in `scripts/check-styles.sh`, not ratchets:

- **No colour or typography property written via `.style`** (`color`,
  `background(-color)`, `border(-color)`, `outline`, `box-shadow`,
  `font-*`, `text-decoration`).  A colour written from script has no
  dark-mode value; toggle a class whose rule rides the palette
  (the `.input-*` value-state cues are the pattern).
- **A `style="…"` attribute inside a JS-built HTML string may only assign
  a custom property or the `display:none` initial state** — the same rule
  templates follow (`chickadee-ui.js`'s `--bar-h` meter is the sanctioned
  example).

What remains counted by the **shrink-only ratchet**
(`JS_STYLE_DECISION_BASELINE` in `scripts/check-styles.sh`) is the residue
the greps cannot classify: computed geometry writes, `setProperty` calls,
and `.style` reads.  It may only decrease.

## Page-local styles

A page `<style>` block is for styling that genuinely exists on one page only.

- Class names are **role-named** (`.guide-textarea`, `.learn-flag`), never
  utility-named (`.mt-1`, `.red-text`).
- A page block may not re-define a selector from the global sheet
  (`.main` is the one allowlisted override).
- No inline `style=""` except a JS-toggled `display:none` initial state or a
  custom-property assignment (`style="--wb-left-width:42%"`).  A component's
  own token is not automatically a per-page dial: `--filter-width` is
  guarded against exactly this use.
- Values inside page blocks follow the same token rules as the global sheet.
- **Total page-block size is a shrink-only ratchet**
  (`PAGE_STYLE_BASELINE` in `scripts/check-styles.sh`).  Concept drift lives
  in page blocks — the same visual idea under a fresh local name, which the
  duplicate-selector guard cannot match — so the escape hatch only shrinks:
  a new shared pattern goes into `styles.css` as a named component (and into
  the vocabulary above).  When you shrink a block, lower the baseline in the
  same PR.

## The maintenance page

`deploy/error-pages/maintenance.html` is served by nginx while the app is
down, must be fully self-contained, and therefore restates palette values
inline.  Every colour literal in it must exist somewhere in
`Public/styles.css` — `scripts/check-maintenance-palette.sh` enforces the
subset — so changing a palette colour means updating the copy there (the
check names the stranded literal).  Its type/radius values mirror the app
scales by hand; each carries a comment naming the token it mirrors.

## Definition of done for any UI change

Run before pushing — CI runs the same thing in `format-lint`:

```bash
scripts/check-styles.sh
```

That one entry point runs, in order:

1. `scripts/check-css-vars.sh` — every `var(--x)` resolves; no
   `var(--x, #hex)` fallbacks.
2. `scripts/check-design-tokens.sh` — colour literals (`#hex`/`rgb(a)`/
   `hsl(a)`) only in palette `--token:` declarations; every `font-size` on
   the type scale; every `border-radius` on the radius scale; every rem
   spacing component on the spacing lattice.
3. `scripts/check-maintenance-palette.sh` — the nginx maintenance page's
   colours are a subset of the palette.
4. Inline-style allowlist, `alert()` ratchets, the inline-script /
   JS-styling / page-style shrink-only ratchets, duplicate/shadowed-selector
   guards.
5. `scripts/check-class-resolution.sh` — every assigned class name resolves
   (see "Class names must resolve").

Interpolated class families are pinned by the Swift side instead:
`swift test --filter StatusClassStylesheetTests`.

For changes that touch `Public/*.js` or the frontend test suite, also run
the JS gate (CI runs it in the `browser-runner-tests` job):

```bash
scripts/eslint.sh
node --test Tests/BrowserRunnerJSTests/*.mjs
```

ESLint is a correctness gate (`eslint:recommended`, zero warnings), not a
formatter; scope and shared globals live in `eslint.config.mjs`.  New
cross-file API should hang off `ChickadeeUI` rather than adding a global.

For changes that add or restructure markup (not just CSS values), also run
the render tests for the affected routes, e.g.:

```bash
swift test --filter WebRoutes
```

and check the page by eye in both light and dark mode — the guards prove the
values route through the system; they cannot prove the page *looks* right.
The visual-regression harness (`Tools/visual-regression/`, CI
`visual-regression.yml`) automates that last check for the key pages: it
screenshots them in both schemes and diffs against committed baselines.  An
intentional look change means regenerating baselines
(`Tools/visual-regression/run-visual.sh --update`) in the same PR.  The same
CI job also runs the axe-core accessibility scan (`run-a11y.sh`) over those
pages in both schemes: critical/serious violations are zero-tolerance,
moderate/minor ratchet down via `a11y-baseline.json`.

A screenshot cannot see everything, though — the capture fires ~300 ms after
load, so it never observes a table's **background repaint**, where the shared
filter, sort, poll and icon-sprite components have to keep working together.
Each of those fails silently there (icons become empty boxes, the sort reverts
to server order, the filter forgets what was typed), and a diff of two
screenshots that both show the failure agrees with itself. `run-repaint-probe.sh`
asserts those four properties directly and runs as a third step of the same
job. If you change any of those components, that probe is the check that will
tell you.

## Extending the system

- **New colour** → add the token pair to both `:root` blocks, then use
  `var(--x)`.
- **New size that truly fits no step** → change the scale in `styles.css`
  and this doc in the same PR, with the reasoning in the PR description.
  A scale with exceptions is just the old sprawl with extra steps.
- **New repeated pattern** (a third page grows the same card/banner/table
  flavour) → hoist it into `styles.css` as a named component and note it in
  the component vocabulary above.
- **New page** → pick an archetype, assemble it from the vocabulary, and add
  it to `Tools/visual-regression/pages.mjs` if it introduces a new shape
  (commit the CI bootstrap capture as its baseline in the same PR).
- **Shrinking the spacing lattice** → when a step's last usage disappears,
  remove it from `SPACING_STEPS` in `scripts/check-design-tokens.sh` in the
  same PR.
- **Migration queue** — superseded as an inventory by
  [ui-consistency-audit.md](ui-consistency-audit.md) (2026-08), which
  audited the whole widget layer, found this queue's five entries were an
  undercount (seven titlebar clones, seventeen action-row names, fourteen
  muted-hint names, …), and carries the sliced conversion plan. Convert
  opportunistically when touching a page, per that document's Slice 7;
  update its status lines rather than growing this bullet.
- **Future ratchets** (candidates, not yet enforced): `font-weight` and
  `line-height` scales.
