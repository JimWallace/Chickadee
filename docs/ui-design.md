# UI Design Principles

How Chickadee's web UI stays visually consistent, and how that consistency is
*enforced* rather than remembered.  The web UI is Elementary views
(`Sources/APIServer/Views/`) + one global stylesheet (`Public/styles.css`);
the render tests only prove pages render, so every rule here is backed by a
guard: a static check in the `format-lint` CI job, a SwiftLint rule, or
`ElementaryPageGuardTests`, which applies the markup rules to every rendered
page.  If a rule matters and has no guard, the history of this codebase says it
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

- **Raw colour literals — `#hex`, `rgb()`/`rgba()`, `hsl()`/`hsla()`, or a
  CSS named colour such as `white` — may only appear as the value of a
  `--token:` declaration in `Public/styles.css`** — never in a rule body, and
  never in a page `<style>` block.  (`transparent` and `currentColor` are not
  fixed colours and stay allowed.)  Everything else uses `var(--x)`.  This is
  what makes dark mode work: a hardcoded `#d4edda` success banner is
  invisible-text-on-dark waiting to happen (that exact bug is why
  `--success-fg` / `--danger-fg` exist).
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

Every page renders inside `BaseLayout` (nav, colour bar, course tabs, `main.main`)
and then follows ONE of these skeletons.  Don't invent an eighth shape —
pick the archetype, and reuse its components.

**Start a new page by copying its archetype's exemplar.**  The component
vocabulary and the idiom table below tell you what to *reach for*; this is
the only rule here that names a **starting artifact**.  It exists because
the skeleton column describes a shape without providing one: an author who
reads it and imitates whichever page they happened to open inherits that
page's private habits along with the archetype.  The example pages in a row
never agreed with each other, so "which one" was a coin flip.  Now one of
them is the answer.

| Archetype | Skeleton | Copy this | Also |
|-----------|----------|-----------|------|
| **Admin tabbed** | `AdminTabs` (the `.admin-version-banner`, the hidden `<h1>`, the tab bar) → `.page-section` blocks, headings starting at `<h2>` | `AlertsPage` | `AdminPage`, `AdminUsersPage`, `AdminAuditPage`, `AdminBrightspacePage`, `AdminGitHubPage`, `AdminLTIPage`, `AdminMCPPage`, `AdminRetentionPage`, `AdminStoragePage` |
| **Instructor tabbed** | `InstructorTabs` → `.page-section` blocks | `InstructorMCPPage` | `AssignmentsPage`, `InstructorActivityPage`, `InstructorBrightspacePage`, `InstructorGitHubPage`, `InstructorLTIGradesPage`, `InstructorNewTermPage`, `InstructorSlipDaysPage`, `InstructorStudentsPage` |
| **Titlebar page** | `.page-titlebar` (`<h1>` left, actions right) → optional `.page-subtitle` → content | `AdminUserPage` | `AdminCoursePage`, `AdminRunnerPage`, `AssignmentFeedbackPage`, `AssignmentSubmissionsPage`, `CourseStudentSubmissionsPage`, `InstructorEnrollCSVPage`, `AssignmentNewPage` |
| **Plain student page** | `<h1>` → content | `AccountPage` | `SubmitPage`, `EnrollPage`, `IndexPage`, `SubmissionPage`, `GitHubSubmitPage`, `LeaderboardPage` |
| **Auth box** | `.auth-box` centred card | `RegisterPage` | `LoginPage`, `OAuthConsentPage` |
| **Body-partial shim** | `BaseLayout` around one shared body view, no markup of its own | `AssignmentEditPage` | `NotebookPage` |
| **Full-bleed app** | `BaseLayout(fullBleed: true)`; owns the viewport | `WorkbenchPage` | `LeaderboardPresentPage` |

Why each exemplar won its row: `AlertsPage` carries no page script and the
least page CSS of any admin page while still showing the whole skeleton;
`InstructorMCPPage` uses no page-private class name at all;
`AdminUserPage` is the only page in its row that demonstrates the optional
`.page-subtitle`; `AccountPage` is the only plain student page that groups
its content in sections at all; `RegisterPage` ties `LoginPage` on page CSS
and private names and wins on having nothing auth-provider-specific to strip
out; `AssignmentEditPage` *is* its archetype: `BaseLayout` around
`AssignmentEditBody`.  `WorkbenchPage` is the sole page that uses the
`fullBleed` flag and therefore its exemplar by default — it is also the least
copyable page here, which is the honest reading of an archetype with one
member.

The pages in the **Also** column are the archetype too; they are just not
the reference.  Two of them are the nearest fit rather than an exact one:
`AssignmentNewPage`'s `.page-titlebar` holds the name input, not an `<h1>`,
and `LeaderboardPresentPage` owns the viewport through
its own `PresentLayout`, not the `fullBleed` flag.  The shim's body view is
the page's whole content: `NotebookPage` is `BaseLayout` around `NotebookBody`,
and the workbench renders `AssignmentEditBody` and `NotebookBody` in its two
panes.

`Tests/APITests/PageArchetypeTests.swift` reads this table —
so the exemplar column and the guard cannot drift apart — and re-checks each
exemplar against its own row on every run.  It reads each exemplar's renders
in `ElementaryPageFixtures`, where the exemplar fixtures are marked
`isExemplar`, and it fails when the flags and the table disagree.  A rule
that names a page's own markup subtracts the shared body views the page
embeds, so the shim and the workbench are judged on what they write, not on
what `AssignmentEditBody` and `NotebookBody` write.  It checks the exemplars
and nothing else: no page fails for not being one.  It does hold them to
slightly more than the skeleton column asks of the archetype at large —
`AccountPage` must keep grouping its content in `.page-section` blocks,
though a one-form page like `SubmitPage` is a perfectly good plain student
page without them.  That asymmetry is the point.  The archetype is the floor;
the exemplar is the reference, and a reference that has quietly stopped
demonstrating the full shape is worse than no reference, because it is still
the page everyone copies.

Anatomy rules that hold across archetypes:

- **Flash banners render through `BaseLayout`** — never hand-rolled.  Pass
  `FlashMessages` to `BaseLayout` for the one-shot messages.  It emits
  `.flash-success role="status"` / `.flash-error role="alert"`.  Write a
  static state banner as `FlashBanner(.warning)` or `FlashBanner(.neutral)`,
  which carries `role="status"`.  SwiftLint keeps the `flash-` classes in
  `BaseLayout.swift`.
- **Tab bars are the `AdminTabs` / `InstructorTabs` views.**  An admin page
  opens with `AdminTabs(active:page:)`, which also renders the version
  banner.  An instructor page opens with `InstructorTabs(active:)`.
- **Headings are structural:** tabbed pages start their sections at `<h2>`
  (the tab bar is the page title); every other page has exactly one `<h1>`.
  Don't restyle a heading to fake a different level.
- **`.page-section` is the one generic section wrapper** (heading + content).
  `.section-block` is the suite editor's per-test-section grouping and
  `.submission-section-block` the results grouping — not general-purpose.
  `.submission-section-heading` is the sub-heading over a grouped
  `.results-table` inside a section (a results section).
  `.assignment-section-heading` is the heading over one group of rows on a
  list page: a course section of assignments, or a roster group.
- Dense/wide tables wrap in `.table-scroll`.

## Component vocabulary

Reuse before you restyle — this catalog is closed in the sense that a new
page must be assembled from it, and a genuinely new pattern must be ADDED to
it (and to this list) rather than approximated privately in a page block.
The audit that produced this rule found sixteen page-local names for "a row
of action buttons" and four pill implementations; the page-style ratchet
(below) now makes the private copy the expensive option.

For a while it made only the *page-local* copy expensive.  The global sheet
carried no budget at all, so the cheapest way to add a second spelling of a
component was to skip the page block and put it in `Public/styles.css` — and
thirteen components went in without ever reaching this list, followed by a
pair of estimate chips that were chips in the changelog, in the commit
message and in their own CSS comment, under a name that shared nothing with
`.chip`.  Every guard passed.  `scripts/check-ui-vocabulary.sh` now prices
the global sheet the same way: the count of classes in it that this catalog
does not name is a shrink-only ratchet, so a new global component costs a
catalog entry, paid here, where review sees it beside the component it would
duplicate.

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
- **`.modal-overlay`** / **`.modal-card`** (+ `.modal-card--confirm`) — the one blocking
  dialog shape.  A destructive action asks with `data-confirm="…"` in
  markup (app.js handles it) or `await ChickadeeUI.confirmAction(msg)`
  where there is no element to mark; both render the same themed
  `role="alertdialog"`.  It returns a **promise** — the native dialog it
  replaced could block the event loop and this cannot — so the
  `data-confirm` seam cancels the interaction, asks, and replays it on
  yes.  Never call the native one: `check-styles.sh` holds it at zero,
  as it does for native alerting.
- **`FlashMessages` / `FlashBanner`** + `.flash-*` — see page anatomy above.
- **`.page-titlebar`** (+ `.page-titlebar--baseline` to align on the text, `.page-titlebar--top` for a tall title column such as the assignment editors), **`.page-subtitle`** — the page
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
- **`.field-inline`**, `.field-stack` (+ `--grow`, `--narrow`),
  `.checkbox-row`, `.field-note` (+ `--muted`), `.field-help`,
  `.input-compact`, `.editor-input`, `.select-xs` — form-field layout, hints,
  and the compact control sizes.
- **`.cell-input`** (+ `--with-check`), `.input-mono`, `.points-input`,
  `.suite-name-input` — form controls embedded in dense table cells (inputs
  panels, case tables, suite rows).  Server-rendered rows and JS row
  builders share these, so the two renderings of one row cannot drift.
- **Value-state cues** — `.input-expression` (green per-student tint),
  `.input-attention` (amber), `.input-invalid` (red), `.input-computed`
  (muted), `.input-ref-ok` / `.input-ref-broken` (italic green/red `$name`
  refs).  Editors toggle these classes; they never write the colours.
- **`.modal-overlay`**, `.modal-card`, `.modal-card--confirm`, `.modal-head`,
  `.modal-body`, `.modal-foot`, `.modal-title`, `.modal-close`,
  `.modal-status`, `.modal-desc` — the one modal shell
  (test-editor-modal.js).  `hidden` does the showing and hiding.
- **`.editor-stack`**, `.editor-cm-mount`, `.cell-stack`, `.cell-title`,
  `.cell-actions` — editor-built layout: vertical field stacks, the
  CodeMirror host, and table-cell title/meta and action clusters.
- **`.results-table`** is a CARD: `background: var(--surface)`, a
  `var(--border)` hairline, `var(--radius-lg)` corners and `overflow: hidden`,
  which is what clips those corners while the table stays
  `border-collapse: collapse`.  The separate box model is NOT required for the
  card look and must not be reached for — `collapse` is what keeps one hairline
  where two bordered elements meet, and switching it doubles every one of them.
  There is deliberately no `--card` variant: a second flavour of the site's
  most-reused component is where the sprawl this rulebook exists to prevent
  starts.  A bordered wrapper around a table drops its own border, since the
  table owns that edge.
- **`.results-table`** (+ `.table-scroll`), **`.sortable-table`** — the one
  column sort (`Public/sortable-table.js`).  Markup:
  `<th data-sort-key="…" data-sort-type="text|number|date|duration">` wrapping
  `<button class="sort-header">` (Swift: `SortHeader`); the cell's sort value is `data-sort-value`,
  else `data-iso`, else a contained `<select>`'s value, else its text — the
  MACHINE value, deliberately not the displayed text `.filter-input` matches
  (you sort Last Seen by its ISO and filter it by "2 hours ago").
  `data-sort-initial="<key>:desc"` declares the load-time sort and
  `data-sort-tiebreak="<key>"` the tie-break; a page that repaints rows calls
  `ChickadeeSortableTable.apply(table)`.  Never hand-roll a sorter or a sort
  glyph — the guard fails on both.  The glyph marks the ACTIVE column only:
  `.sort-header::after` carries it at `visibility: hidden` so the box holds
  its width, hover and `:focus-visible` reveal it, and `th.sort-asc` /
  `th.sort-desc` show the direction permanently.  A resting glyph on every
  header drew one arrow per sortable column and said nothing about which
  column the rows were ordered by.
  A column that declares `data-sort-key` also becomes **searchable** by
  `.filter-input`, which matches its DISPLAYED text while the sorter reads its
  machine value — you sort Due by its ISO and filter it by "in 2 days".  Adding
  a sort key therefore widens the filter as a side effect; omitting one
  (Actions, History) is how a column stays out of both.
  **`.row-last-visible`** closes the list: the table's own border ends it, so
  the final row draws no separator.  `:last-child` alone is wrong on any
  filtered table — it is the DOM's last row, while `list-filter.js` hides rows
  with the `hidden` attribute — and the stale separator then collapsed with
  the table's bottom border and won it, rendering that edge a shade lighter.
  `list-filter.js` owns the class (it is the only thing that knows which rows
  are hidden) and `sortable-table.js` asks it to re-mark after reordering.
  A page never writes it.
- **`.diagnostics-cards`** + `.diagnostic-card`, `.diagnostic-label`,
  `.diagnostic-value` — stat tiles.
  `.diagnostics-section` wraps a group of them under one heading.  A dashboard
  tile that a script fills from `/metrics/cards` is `MetricsDiagnosticCard`.
- **`.chip`**, `.chip-row` — neutral tags.  A chip is the answer for a short
  labelled value beside a control; it carries no status colour, so if the
  value needs one it is a `.tier`, not a chip.  `.chip-ok` / `.chip-err` add
  pass/fail colouring to an inline count.  `.tier` + `.tier-*` — status
  badges (defined variants only:
  open/closed/extended/preview/unpublished/danger).  A bare `.tier` is the
  neutral state badge, for a state with no status colour ("Secret tests
  revealed").  `.tier-danger` is the one
  that means something went wrong; `.tier-closed` is a neutral inactive grey
  and must not be borrowed for it.
- **`.account-identity`** — the account page's identity header: the resolved
  name and the username under it.  The bird is not here: it is in the
  `.bird-card` just below.  The name
  and username are element selectors inside the row, not classes of their own.
  The name resolves display name → preferred name → username, and the username
  line is omitted when it would merely repeat the name.
- **`.avatar`** and the `.av-*` part classes — the generated student bird.
  One `<svg>` carrying the size class wraps seven `<use>` elements naming
  symbols in `Resources/Sprites/avatar-sprite.svg`: backdrop, then — inside one group that
  carries the tilt transform — tuft, plumage, wing, expression, accessory, and
  last, on top and untilted, the ring.
  **`BaseLayout` includes `AvatarSprite` once on every signed-in page**,
  because the nav shows the user's own bird. A page does not include it
  again. `PresentLayout` has no nav, so the Present page includes it itself;
  a new layout that shows a bird must do the same, or the page still returns
  200 and shows an empty circle, which no guard can catch.  Nine colours are per-student
  (`--av-cap`, `--av-wing`, `--av-body`, `--av-bib`, `--av-beak`, `--av-mark`,
  `--av-accent`, `--av-backdrop`, `--av-border`, assigned inline, which is
  the sanctioned form); `--av-border` colours a solid
  ring (`.av-ring`) and is the transparent `--avatar-border-none` for every
  other ring.  The patterned rings colour themselves by class
  (`.av-rainbow-*`, `.av-spectrum-*`, the term ramps `.av-winter-*`,
  `.av-spring-*` and `.av-fall-*`, or the student's `.av-accent` and
  `.av-cap`), and the **staff ring** (`.av-staff-ring`, a double ring in a
  colour no student ring uses, with a dark-mode mirror) is drawn from a course
  role, never from a stored choice.  `.avatar` sets `forced-color-adjust:
  none`: the bird is decorative, and forced colors would otherwise repaint it;
  the colourway's six tones (`.av-cap`, `.av-wing`, `.av-body`, `.av-bib`,
  `.av-beak`, `.av-wing-mark` and `.av-brow`) read the per-student `--av-*`
  properties, and the fixed parts — `.av-eyewhite`, `.av-pupil`, `.av-glint`,
  `.av-blush`, `.av-mouth`, `.av-gear`, `.av-gear-line`, `.av-bloom-eye` —
  read the palette directly.  The colourway decides the species (one of eleven,
  [avatar-species.md](avatar-species.md)); the eyes and the body circle are
  the same on every species and keep the birds one family, and each species
  has its own beak.  `.av-eyewhite` is the fixed white: the eye disc, and a
  white wing mark where a species' own wing art needs one.  **Six sizes.**  `.avatar` alone is 3rem: the
  bird earns its detail at 48px and up.  `.avatar-sm` (1.5rem, inline) is for a
  row where the handle beside it carries the identity — the bracket, and
  the nav's account menu, where the user's name is beside it —
  because below 48px the bird is recognition, not identification, and a row
  with no text beside it would want a monogram chip instead.  **`.avatar-md`**
  (2.25rem) is the roster size: a row on the instructor Students, Slip days or
  LEARN list, where the name beside the bird carries the identity and the bird
  is the student's own seeded one, the same as on their account page.
  The submitting student's bird on a result page (`.submission-bird`) is
  **`.avatar-result`** (3.5rem, `AvatarSize.result`). Staff reading a
  student's result see that bird as stored, with no reaction
  (`.submission-bird-other`). On the student's own page, on a clean pass it
  wears the `chirp` face for that page only and hops twice
  (`.submission-bird-cheer`), and not at all under
  `prefers-reduced-motion`; it never looks sad (`AvatarReaction`). A gain
  plays the result-page celebration once instead
  ([result-celebration.md](result-celebration.md)): `celebrate.js` adds
  `.is-celebrating` to the group and the page, shows each row's mark as
  `.result-mark-skipped` until its beat, counts the grade up in
  `.score-figure-counting`, and draws feathers on one `.celebrate-canvas`
  overlay that ignores the pointer. A full-marks grade on the student's own
  page reads in the open colour (`.score-figure-perfect`), and an
  improvement shows its gain in a `.tier .tier-open` pill.
  The user's own bird (the nav's, the result page's, the account card's)
  leans a little when the pointer or the keyboard is on it, and the account
  card's large bird breathes slowly and hops while it is pressed. It is CSS
  only, with no script and no change of face. All of it sits behind
  `prefers-reduced-motion: no-preference`, and a roster or leaderboard bird
  does not react to the pointer (#2589); the one other person's bird that
  moves is on the Present-mode podium (`.podium-place .avatar`, below).
  **`.avatar-lg`** (6rem, `AvatarSize.hero`) is the leaderboard "you" card and
  **`.avatar-xl`** (10rem, `AvatarSize.podium`) a Present-mode podium place.
  Present mode alone scales its birds past the class, because the room reads
  them from the back row: first place 12rem, second and third 9.5rem, places
  four to ten 3.5rem, and a bracket's `.avatar-sm` birds 2.25rem.
  Nothing is drawn on the bird to mark a rank.  See
  [student-avatars.md](student-avatars.md).
- **Leaderboard classes.**  `.you-card` (the viewer's card: bird, handle, place,
  best and next place) with `.you-card-who`, `.you-card-name`, `.you-card-rank`
  and `.you-card-stats`; `.you-pill` (the solid **You** mark, never a
  left-border accent); `.rank-disc` (the place number, with a gold, silver or
  bronze tint only for ranks 1 to 3 through `data-rank-tier`; every other rank
  is a plain numeral); and on the `.section-items` list `.leaderboard-rank`,
  `.leaderboard-row--you` (the viewer's row, tinted `--you-bg`) and
  `.leaderboard-gap` (a run of rows folded away, as plain text).
  A `.leaderboard-more` row under the list toggles a student between their
  window of it ("Show all N") and the full list ("Show my standing").
  A live session's countdown is a `.tier`: `.tier-open` while submissions are
  accepted, and the neutral bare `.tier` before it opens or after it closes.
  The tokens are `--you-bg`, `--teal-ink`, `--teal-ink-fg` and the
  `--rank-gold|silver|bronze-bg|fg` pairs, each with a dark-mode value.
  The hill holder and the tournament winner share the card as
  `.champion-card`, pale gold (`--champion-bg`), with a `.you-card-kicker`
  line.  When the viewer holds it, its markup carries both `champion-card` and
  `you-card`, and the card takes the you tint.  A tournament is a `.bracket` of `.bracket-round`
  columns (`.bracket-round-label`) of `.bracket-match` cards of two
  `.bracket-entrant` lines (`.bracket-entrant--won` bold,
  `.bracket-entrant--you` tinted), inside a `.table-scroll`.  A won tag is
  `.tier-open`; a live tag is `.tier-preview`.
  **Present mode** (`LeaderboardPresentPage`, staff only, dark whatever the
  viewer prefers, no site chrome) is a `.present` page: `.present-header` with
  `.present-kicker`, `.present-title` and `.present-clock` (a
  `.present-clock-label` over a large `.present-clock-time`); then a
  `.present-stage` of two columns.  On the left, a `.podium` of three
  `.podium-place` columns (`.podium-handle`, `.podium-value`, and a
  `.podium-plinth` whose top edge takes the place's gold, silver or bronze; the
  first-place bird is 12rem, the others 9.5rem; the hill's holder carries a
  `.podium-kicker`).  The podium birds (`.podium-place .avatar`,
  `podium-bounce`) bounce, third to first, when the board first shows and
  when the top three change; after a `chickadee:table-repaint`,
  `present-podium.js` marks a podium with the same three `.podium--settled`,
  the off switch, which stills them. The bounce runs by default, unlike
  `.composite-slot--arrived`, because the first render must bounce with no
  script, and nothing moves under reduced motion (#2591).  On the right, places four to ten as `.present-rows` of
  `.present-row` lines (3.5rem birds; `.present-row-handle`,
  `.present-row-value`).  A tournament replaces the stage with a
  `.present-bracket` (the page's bracket at display scale) under the winner's
  `.champion-card`, gold on this page; a hill holder who is not on the podium
  gets the same card.  A tournament with no session window shows where the
  run stands in the clock's place.  A browser-graded tournament adds the
  projector arena to the toolbar: a "Play matches" `btn action-btn` and a
  `.text-quiet` `role="status"` line that names the match it plays by round
  and position, never by student (`tournament-arena.js`).  A `.present-footer` ends the page, with a
  `.tier-preview` Live tag while it polls.  Display sizes are `em` of one size set for a 1600-pixel screen; the
  page steps by `zoom` (down at 1500 pixels, up at 1900), since the type scale
  forbids a fluid font size.
- **`.composite-stage`** (the `composite-*` family) — a class composite
  (docs/class-composite.md): a `.composite-frame` that holds a pixelated
  `.composite-canvas`, and one `.composite-slot` cell for each slot. The cells
  lie over the canvas in a grid (`.composite-slots--overlay`) or make a strip
  under it (`.composite-slots--strip`). A cell state is
  `.composite-slot--empty`, `--failed`, `--passed`, `--reference` (a reference
  render, under the `--composite-reference-dim` wash), `--rendering` (a pulse)
  or `--arrived` (a gold flash). The view sets `--composite-cols`,
  `--composite-rows` and `--composite-aspect`. `class-composite.js` sets the
  cell classes only, and a cell's `title` repeats the holder list on the page.
  A `.composite-scrub` range follows the Pause button in a `.toolbar`. The
  frame polls in the `json` mode of `table-poll.js`, outside any polled region.
  Present mode wraps it in `.present-composite`, which makes it as large as the
  screen permits, and puts the progress in the clock's place. The result page
  wraps it in `.composite-tile`, which shows one student's contribution. In the
  strip, passed is `--green` and failed is `--red`, the test-status pair, and
  reference is `--gray-300`, between empty and passed in both themes.
- **`.fieldset-plain`** — the unstyled `<fieldset>` + bold `<legend>` that
  wraps a group of radio or checkbox choices (enroll, the LTI grade
  transport, LTI deep linking, the bird picker).  Use it for any group
  of choices rather than restyling a fieldset.
- **`.swatch-row`**, `.swatch`, `.swatch-sample`, `.swatch-name` — a choice of
  one colour, inside a `.fieldset-plain`: each option is a radio input shown
  as a round sample with its name under it.  The input is invisible but stays
  in the tab order, so the group works with the keyboard and with no
  JavaScript.  The checked option has a ring and a bold name, so the state
  does not depend on colour alone; in forced-colors mode the samples keep
  their colours and the ring is the system `Highlight`.  The sample reuses the
  avatar's own custom-property names, set per option: `.swatch-backdrop` (a
  filled disc, `--av-backdrop`), a ring sample (a small `<svg>` drawing the
  backdrop and the ring symbol from the avatar sprite; it inherits
  `--av-backdrop` from the form, so it follows the previewed backdrop) and
  `.swatch-none` (a dashed ring, for "no border") and `.swatch-bird` (the
  student's own bird wearing a face, an `Avatar` at the roster size, so the
  face reads; it brings its own properties, so it shows the SAVED backdrop
  and ring, not the previewed ones, while the ring samples follow the preview).
  An option that cannot be chosen yet is not a swatch: see `.bird-locked`.
  Used by the account page's `.bird-card`.
- **`.bird-hatch`** — the hero bird on the first page after a hatch (#2590):
  the bird with `.bird-hatch-egg` over it, two `.bird-hatch-shell` halves
  (`.bird-hatch-shell--top`, with a zigzag crack edge, and
  `.bird-hatch-shell--bottom`) in the chickadee's cream: the egg reads
  `--avatar-ink-body` on purpose, so it is the colour of the mascot's breast
  in both themes, and like `.avatar` it sets `forced-color-adjust: none`. The egg wobbles,
  splits and falls away while the bird grows out of it, all filling forwards
  so the end state is the plain bird. The egg exists only inside
  `prefers-reduced-motion: no-preference`; every other reader sees the bird.
- **`.bird-card`** — the account page's "Your bird" card (a `.card`).  An
  optional `.bird-card-strip` across its top holds a hatch's confirm or its
  result, tinted `--you-bg`: the birds, the text and a `.toolbar` of actions.
  The result strip is not a second flash: it carries actions, and the
  redirect lands at the card, where a flash at the page top is off screen.
  Under it, `.bird-card-body` is a wrapping flex row of
  two items, so the columns stack on a phone with no media query:
  `.bird-card-hero`, a light panel with the bird at `.avatar-xl` (the
  `AvatarSize.podium` size, reused; inside `.bird-hatch` on the first page
  after a hatch), the handle in `<strong>` above the
  species (a student's bird only; a staff bird has no handle, and the species
  is the strong line), the hatched date and the
  hatch control, `.bird-card-hatch` (a link to the confirm, or a disabled
  button with none left, and its caption);
  and
  `.bird-card-groups`, the form with the Face, Backdrop and Ring fieldsets and a
  `.toolbar` footer.  Inside the groups every `.swatch` is a 44px hit target;
  a named swatch (a face, a ring) shows the checked state on the whole
  tile, and a backdrop keeps the ring around its disc.  A backdrop is the one
  swatch whose name is `.visually-hidden`: the eight discs are the choice,
  and the checked one has the ring.  `.bird-locked` lists
  the faces and rings not open yet under a dashed rule: a dimmed sample, a lock icon and
  "Name · earned", or for a term ring "Winter · opens in January".  They are list items, not disabled
  radios, because nothing about them can be chosen.  The ring a student
  already wears is never listed there.  The live preview (`avatar-picker.js`)
  copies the checked option's tokens onto the hero bird and points its ring
  and face layers at the checked symbols; it also keeps Save disabled and "Undo changes"
  hidden until a choice changes.  See [student-wardrobe.md](student-wardrobe.md)
  and [avatar-species.md](avatar-species.md).
- **`.item-main`, `.item-status`, `.item-actions-td`** — name the cells of a
  `.section-items` row: the title and details, the state or value, and the cell
  that holds the actions.  They change nothing on a desktop; at 640px and below
  the row becomes a wrapping flex line (tile, title, state, then the actions on a
  line of their own under the title), still a table to a screen reader.  Put them
  on the cells of any new `.section-items` list; the existing `.item-tile-cell`,
  `.section-items-handle` and `.leaderboard-rank` stay.
- **`.diagnostic-value-alert`** — the one count in a tile row that is not
  neutral information (the submission band's failed count), in `--red`.  A
  modifier on `.diagnostic-value`, not a second tile component.
- **`.secret-reveal-action`** — the reveal-token form where it belongs: at the
  end of the hidden-test block's header, acting on the block it labels, rather
  than as a notice of its own elsewhere on the page.
- **`.score-summary`**, **`.score-delta`** — the submission result band's two
  parts: the stacked grade block (label, figure, points) and the whole-band
  delta remark, which takes its own full-width line beneath the count tiles.
  Both exist because the band is two groups plus a footnote rather than one row
  of peers — flattened into a single flex row, the tiles wrapped 3+1 on every
  attempt after the first, where a delta line joins the row.
- **`.score-figure`** — the submission result page's grade percentage, the one
  figure a student opens that page to read, at `2.4em`.  The only display-size
  type in the product: the `--text-*` scale tops out at 1.4rem for page
  headings and deliberately does not carry display sizes, so this is `em`
  against its container rather than a new scale step.  One per page.
- **`.diff-table`** — the one unified diff listing (the instructor's
  starter-to-submission page).  Rows are `.diff-added` / `.diff-removed` /
  `.diff-context`, or `.diff-fold` standing in for a run of unchanged lines;
  cells are two `.diff-gutter` line-number columns and one `.diff-line`;
  `.diff-marker` is a notebook cell boundary.  A second comparison view
  (two attempts, two students) reuses this rather than minting a twin.
- **`.text-muted`**, `.card-meta`, `.fine-print` — muted text.
- **`.section-items`** — the student dashboard's section list: one
  `.results-table`, five fixed tracks (`.section-items-tile`,
  `.section-items-status`, `.section-items-grade`, `.section-items-actions`,
  and the flexible name track).  Rows stay in the instructor's order, so section
  tables do not sort.  A graded row, a material row and a `.section-items-heading`
  row each fill only the cells that apply.  The `thead` is `.visually-hidden`,
  not removed.  Each row leads with an `.item-tile` (in an `.item-tile-cell`),
  a square glyph coloured by `data-kind` (`slides`, `notebook`, `document`,
  `link`, `outline`, `graded`) from the `--kind-*` token pairs — one component
  with an attribute, not six classes.  The name cell is an `.item-title` over an
  `.item-details` line; `.item-grade` right-aligns the grade.  A material's
  buttons are `.action-btn-icon`, the same fixed square as an assignment's.
  A section filter appears only at `IndexDisplayGroup.filterThreshold` (8) rows
  or more, and never on the ungrouped bucket.
- **`.section-items--manage`** (with `.section-items-handle`,
  `.section-items-count`, a 5rem trailing track: the Overview's submitted count, the Activity list's single eye button) — the instructor Overview's variant of
  `.section-items`: the same row shape with a leading drag-handle track and a
  submitted-count track, and a wider state track for the status select.  Rows
  stay `<tr>` in a `tbody[data-section-id]` and keep their `data-assignment-id`
  / `data-content-item-id`, because `section-items-dnd.js` reads them.
- **`.editor-split`** — an editor (a form) beside a facts `.card`; one column on a phone. The authoring-voice section of the instructor AI agents page.
- **`.facts-actions`** — the buttons at the top right of a facts card (a `.detail-grid` in a `.card`): Test connection and a ⋯ on the LEARN page.
- **`.section-items-combo`** (20rem) — the state track of a `.section-items` list whose control is a combobox plus its Save button.
- **`.add-panel`** — a form that opens under a page or section header: the
  add-material form, the add-staff form, the slip-day settings.  Closed until a
  control carrying `data-add-target` opens it; `app.js` toggles `is-open` (and
  preselects a kind when the control carries `data-add-kind`).  Without JS the
  control links to the panel's id and `:target` opens it.  A link from another
  page opens a panel the same way, so Cancel also sets `is-closed`, which wins
  over `:target`.
- **`.section-items-seen`** — the last-seen (or last-active) track of a
  `.section-items` list.  It is wide enough to hold the longest relative time
  on one line, so a ticking time does not change the row height.
- **`.row-menu`** (with `.row-menu-panel`, `.row-menu-item`,
  `.row-menu-item--danger`) — the trailing ⋯ on a row, and the panel shell of a
  `+ Add ▾` menu.  Write a ⋯ as `RowMenu(for:)` with the items inside;
  SwiftLint keeps its shell in `RowMenu.swift`.  A ⋯ is an `ext-details` whose
  panel is a `.popover-panel`, so the app.js floater lifts it out of the
  table's overflow clip; a `+ Add` is a
  `popup-anchor` with the `.suite-section-popup` shell.  Outside click and
  Escape close every such popup, and Escape returns focus to the summary.  The
  summary's `aria-label` names the row.  A menu is never empty: render none
  when nothing is left to offer.  Destructive items go last in
  `.row-menu-item--danger` and keep their `data-confirm`.  An item that adds
  something carries a small `.item-tile` and may add a one-line `.card-meta`
  hint.
- **`.pips`** (with `.pip`, keyed by `data-state`) — one dot per unit of a budget
  or capacity: a student's slip days (`used` hollow, `left` teal, `extra` — a
  granted day not yet spent — amber) and a runner's job slots (`used` free,
  `left` busy, `extra` when every slot is busy).  Decorative and `aria-hidden`;
  the text beside it ("2 of 3 left", "2 of 4 busy") is the value.
- **`.item-tile`** also takes `data-kind` `ok` (green) and `alert` (red) for a rule
  that is fine or firing.
- **`.item-details--danger`** — a details line that reports a problem (a timeout's
  limit, a failed delivery, "No course access"): the same line in danger red.
- **`.detail-grid--cells`** — the facts panel as an auto-fitting grid of
  label-over-value cells (`<div><dt>…</dt><dd>…</dd></div>`), for ten or more
  facts (the runner detail); omit a fact with no value rather than showing a dash.
- **`.spark-chart`** (with `.spark-chart-scale`, `.spark-chart-axis`) — a sparkline
  drawn large: a 100 / 50 / 0 scale, a taller plot and an x-axis of times, around
  the same `.diagnostic-spark` bars (height from `--bar-h`).  `data-state` on a
  `.spark-fill` turns a full bar amber and an idle one grey.  The numbers also sit
  in a visually hidden table after the chart.
- **`.log-entry`** (with `.log-entry-cell`, `.log-entry-when`) — a log entry whose
  whole row is one `<details>`: the summary is the row (tile, actor and action,
  outcome pill, time, a chevron that turns) and the panel under it is the payload
  as a `.detail-grid`.  The audit log, under day headings; a log stays unsortable.
  It replaces the `.test-output-row` + `.test-output-details` pairing for log tables, so a new log page does not use the old pair.  A one-field edit on a facts card (the alerts webhook) is a `.popup-anchor` popover, the house idiom for a small form.
- **`.share-bar`** — a 4px track with a teal fill whose width is the `--share` custom
  property (a percent the server worked out for that row); the percent label beside
  it is the value.  Storage, by assignment.
- **`.row-muted`** — a list row that is switched off or finished (a disabled LTI
  platform, a revoked or expired agent): dimmed, still readable.
- **`data-copy-url`** — on a button: copies a link to the clipboard (a path gets this
  site's origin put in front of it; an absolute URL is copied as it is) and adds
  `.action-copied` and a "Copied!" title for two seconds.  The copy-student-link
  button on a dashboard row and the LTI tool URLs.
- **`.page-crumb`** — the group name ("Data", "Integrations") in small capitals
  above an admin page title, or the course above a leaderboard's title, as its
  course tab names it.
  Visual only; the `h1` already names the page.
- **`.row-menu-spacer`** — an empty 1.95rem square in the place of a ⋯ menu when a
  row type only sometimes has one, so the actions track lines up.  Never an
  empty menu.
- **`.state-select`** — a real `<select>` in a wrapper whose dot shows the
  state (`data-state`: open, visible and instructor are teal; preview and ta are
  `--state-amber`; anything else is grey).  The select text is the value; the
  dot is only the scan cue.  It holds what is changed most on a row.  A select
  here has no native arrow: the wrapper draws its own chevron, because a native
  select can ignore the padding that keeps the dot clear of the text.
- **`.row-phone-meta`** — a table's phone-width restatement of the columns
  `.col-hide-phone` drops below 640px: the student dashboard's Due and History,
  the admin runners table's version and job count.  Sits inside the name cell,
  takes `.card-meta` typography, and is `display: none` at every width that
  still shows those columns, so the fact never appears twice.  A table that
  hides columns on phones and wants them restated reuses this one — the name is
  the mechanism, not the first table that needed it, precisely so the second
  table does not mint a twin.
- **`.text-error`** / **`.text-ok`** / **`.text-quiet`** — status-line colours
  (`ChickadeeUI.setStatus` toggles them; nothing writes `el.style.color`).
- **`.empty`** — the "nothing here yet" line a list renders in place of rows.
- **`.ext-details`/`.ext-panel`/`.ext-field-*`** — inline set/clear popover
  forms.  `.popover-panel` is the same shape for a row-anchored panel that
  is not a set/clear form; `app.js` floats both.
- **`.nav`**, `.nav-brand`, `.nav-brand-logo`, `.nav-link` — the site header
  in `BaseLayout` (`SiteNav`), on every page.  `.nav-user`, `.nav-username`,
  `.nav-dropdown`, `.nav-dropdown-toggle`, `.nav-dropdown-caret`,
  `.nav-dropdown-menu`, `.nav-dropdown-item`, `.nav-dropdown-item-active` —
  the account menu; `app.js` toggles `.open` on the `.nav-dropdown`, and the
  caret and menu follow from that one class.  This is the only pop-out menu
  shape outside `.popover-panel` and the modal shell — a page needing a third
  is a conversation, not a new rule.
- **Mascot imagery** — `.nav-brand-logo` (site chrome), `.auth-logo` (sign-in),
  `.error-bird` (error page).  The nav mark is the NEUTRAL bird and is never a
  pose: chrome must not say anything about the page it frames.  A pose belongs
  only on a page whose whole job is one state.  A pose keeps `alt=""` where
  adjacent text already states that state — the error page's `.error-code` and
  `.error-title` do — but where nothing else states it the image is the only
  carrier and needs an accessible name.  `Assets/` holds the 384x384 source; the
  copy served from `Public/images/` is sized to its display box, not shipped at
  source size.
- **Drag to reorder** — one vocabulary, two surfaces.  The grip is
  `.section-drag-handle` (course sections, test sections) or
  `.suite-drag-handle` (suite rows); the row in flight takes
  `.section-dragging` or `.suite-row-dragging`; the target cue is
  `.drop-before` / `.drop-after` for "land beside this" and `.drop-adopt` for
  "become a child of this", with `.suite-root-drop` the empty tail target and
  `.drop-hover` its lit state.  `.section-dragging` is deliberately shared —
  `assignments.js` and `suite-table.js` both apply it to a `.section-block`.
  A third reorder surface reuses these; it does not mint a third grip.  The
  Overview's assignment rows are that third surface: a row in a table takes
  `.suite-drag-handle` and `.suite-row-dragging`.  There the whole `<tr>` is
  the drag source (`section-items-dnd.js` sets `draggable` on the row, where
  the suite table sets it on the grip), so `tr[draggable="true"] td` carries
  the grab cursor across the row and the grip is a signpost.  A control inside
  such a row keeps `pointer`.  A row that navigates on click (`tr[data-href]`,
  the instructor roster) shows `pointer` across the row.
- **`.drop-zone`** (+ `.drag-over`, `.drop-filename`) — file-drop upload
  targets.  Unrelated to the reorder cues above despite the shared verb.
- **`.card`**, `.notice-box`, `.error-box` — surfaces and callouts.
  **Two empty states, and they never borrow each other's words.** An empty
  COLLECTION (term start, a course with no assignments) replaces the table: an
  `.empty` line, one `.section-note` of context, one route out.  A filter that
  matched NOTHING leaves the rows in place — hidden, not absent — so the table
  stays and the message appears inside it, worded by `data-list-filter-empty`
  and naming the row type ("No assignments match this filter."), never a
  generic "No results."  The rule: a filter's empty message never claims the
  collection is empty, and an empty collection never mentions a filter.  A
  server-side GET filter is the one place a page decides between the two
  itself, because there the non-matching rows really are absent.
  `.standin-panel` — the placeholder a panel shows while its content is
  unavailable.  `.detail-grid` — label/value pairs in a two-column grid.
- **`.log-payload`** — the `.detail-grid` inside a log/event row's payload
  disclosure (the audit log, alert firings).  A log row shows when, who, what
  and how it went; everything else — category, target, remote address,
  metadata, delivery — goes in a `<details>` that stays closed, so the payload
  stops competing with the facts a reader scans.  It rides the same full-width
  second row as a submission's output panel — `.test-output-row` + `colspan` —
  with `.test-output-details` as the disclosure and a `.detail-grid` inside it.
  A payload in a last column instead would wrap JSON into whatever width the
  fixed columns left over.
  The same second-row disclosure may hold a row's edit form when the form is
  too long for the row (the admin LTI platforms table); give its `<summary>`
  a visually hidden copy of the row's name, so a screen reader can tell one
  "Edit" from the next.
- **`.disclosure-summary`** — the `<summary>` of a `<details>` that a reader
  opens occasionally, such as the options under a form.  It starts with an
  `.accordion-caret` (a span around the `#i-chevron-right` icon), which turns
  while the details is open.  Do not use `.test-output-details` for this:
  that is the disclosure of a result row or a log row.
- **`.page-heading`**, `.titlebar-subtitle` — a heading and its subtitle
  inside `.page-titlebar`.  `.section-gap` adds the standard gap between
  stacked sections.
- **`.icon`** — every inline stroked SVG icon, referencing a `<symbol>` in
  `Resources/Sprites/icons.svg` by `<use href="#i-…">`.  Geometry may appear
  in exactly two files: that sprite, and `Resources/Sprites/avatar-sprite.svg`
  for the avatar parts.
- **`.textarea-mono`**, `.form-stack` — a monospace textarea and
  the stacked form column that usually holds one.

If two pages need the same rule, it belongs in `Public/styles.css`, not
copied into both `<style>` blocks — the duplicate-selector guard fails CI on
copies, and the page-style ratchet fails CI on growth.

### Row anatomy for lists of things

One shape serves the student dashboard, the instructor Overview, Students,
Slip days, Activity, LEARN and the AI agents page.  A row is a tile (content kind,
activity category or the person's avatar), a name, one details line, a fixed
state track and a fixed right-aligned actions track.

1. **One row shape.**  Secondary columns fold into the details line.
2. **One state track** holds what changes most, as an inline control: status,
   visibility, role, an assessment, a balance.
3. **Primary and ⋯.**  Show one or two everyday actions.  Everything else, and
   every destructive action, goes in a `.row-menu` that is the last slot.
4. **Adds merge.**  A page or section with more than one add gets one
   `+ Add ▾`.
5. **Settings are facts.**  A settings form renders as a `.detail-grid` of
   current values with an Edit control; the form opens on demand.

A Filter box appears only on lists of `ListFilterPolicy.minimumRows` (8) rows or
more.  Column headers render, visually, only on a homogeneous list that sorts.

## Interaction idioms

The component vocabulary answers "what class do I write".  This answers the
question before it: **which of the ways this UI already has of doing a thing
is the right one** — and the default answer is that there are enough.  A
page that introduces a fifth way to reveal detail has not added a feature;
it has made the other four less meaningful.

Reaching for detail, cheapest first.  Pick the first one that fits:

| The reader | Idiom |
|---|---|
| should just see it | put it on the page — a `.chip` for a value, `.field-note` under a control, `.card-meta` under a title |
| wants it occasionally | `<details>` + `.disclosure-summary` with an `.accordion-caret`, closed by default |
| is acting on one row | `.ext-details`/`.ext-panel`, or `.popover-panel` |
| must decide before anything else happens | `.modal-card` — the only blocking shape, and only for a decision |
| wants a reminder of what a control is | `title` — a phrase, and never the only copy of something they need |

**Keeping a page current is one mechanism, not a per-page decision.**
`Public/table-poll.js` is it, driven entirely by data attributes, and there is
no second poller:

| Attribute | What it says |
|---|---|
| `data-poll-url` | the server endpoint rendering the replacement, from the SAME view the page rendered inline |
| `data-poll-interval` | milliseconds between polls (default 5000) |
| `data-poll-swap` | `region` replaces the element's own contents; `json` replaces nothing and hands each changed JSON body to the element as a `chickadee:poll-data` event; omitted replaces its `<tbody>` |
| `data-poll-until` | an instant after which the poll stops for good; omitted polls while the tab is open |

Every poll is conditional (ETag / 304) and carries `X-Background-Refresh: 1`,
and it is suppressed while the tab is hidden, while focus is inside the
element, while a `<details>` in it is open, and while its filter box has
focus. Prefer the default `<tbody>` swap: a region swap destroys the whole
subtree, so a sortable table inside one loses its click handlers — the file
says so at `swapTargetFor`. A region swap keeps two kinds of reader state: a
filter box pointed at a table inside the region is applied again, with its
no-match message, and its focus defers the poll; and each `.table-scroll` in
the region keeps its horizontal scroll. A page with a polled element must load
`table-poll.js`; the base layout does not. Reach for `region` only when the
rows do not move alone, as on a class activity's leaderboard, where the
champion banner, the tournament status, the union count and the session
countdown all change with the table beside them. Reach for `json` only for something the page draws rather than
renders: the class composite's canvas, whose pixels a region swap would throw
away. It polls at once, then on the interval. Whatever the mode, keep a page's
fixed chrome — its heading, its chips, its intro — OUTSIDE the polled element.

The affordances that say an element is interactive are a **closed registry**,
enforced by `scripts/check-ui-vocabulary.sh`:

- `cursor` — `pointer` (activates), `not-allowed` (disabled), `grab` /
  `grabbing` (drag to reorder), `col-resize` (the workbench splitter),
  `default` (deliberately not interactive).
- `text-decoration` — `underline` (a link), `line-through` (superseded),
  `none`.

Adding a value is allowed and sometimes right, but it is an edit to this
list and to that script, with the reasoning in the PR — not a line in a rule
body.  The registry exists because `cursor: help` and a dotted underline
arrived together as a private convention for "hover me", in a codebase that
already had four ways to reveal detail and no fifth one it needed.

Two things a hover title is not.  It is **not a disclosure**: no touch
device shows it, no in-page search finds it, and screen readers treat it
inconsistently, so anything a reader actually needs must exist somewhere
else.  And it is **not a docs page**: if the answer runs to sentences, the
sentences go in `docs/`, and the UI links there.

## UI copy

Chrome is not prose.  A label names a thing; it does not explain it.  The
[authoring-voice guide](../CLAUDE.md) governs assignment *content* — what
instructors and students read as course material — and this is its
counterpart for the interface around it.

- **Labels and chips: a noun phrase.**  Two or three words.  `similarity
  20%`, not `Students share about 20% of their rows with each other`.
- **Hover titles: one phrase, 20 words maximum**, enforced by
  `scripts/check-ui-vocabulary.sh` for titles written in templates and by a
  word-budget assertion for any assembled server-side (see
  `datasetEstimateTitleWordCap`).  Name what the number is.  Do not derive
  it, qualify it, or give its worked example.
- **Notes under a control: one sentence**, in `.field-note` or
  `.field-help`, and only when the control's own label cannot carry it.
- **Everything longer belongs in `docs/`.**  A measurement's method, a
  band's two bad ends, why a default is what it is — these are real and
  worth writing down, in a file a reader can link to, search, and correct.

The test for a number the UI shows: an instructor should be able to read it
at a glance and know whether to act.  If it needs a paragraph before it means
anything, the paragraph is not the fix — either show a number that speaks for
itself, or move it out of the control row.

## Timestamps

Two renderings, chosen by what the reader is asking (UI audit S8):

- **Human activity** — "last seen", "authorized", "last used", "fired",
  "completed", an activity feed — renders **relative** via
  `<td class="js-relative-time" data-iso="…">`, which
  `Public/relative-time.js` (loaded by `BaseLayout`) rewrites to "3 hours
  ago" and gives an absolute `title`.  The reader wants recency, and a
  relative value answers that at a glance.  A **countdown** (a token's
  expiry) is the same case: "in 3 days" beats a date.  The component
  **keeps ticking** — at a cadence set by the freshest stamp on the page,
  paused while the tab is hidden and caught up on return — so a page needs
  no timer of its own and a stamp is never older than the tab.
- **Forensic or compliance** times — the audit log, retention dates —
  render **absolute**, in `--font-mono`, deliberately.  Here the exact
  instant *is* the content, and "2 months ago" would destroy it.
  The audit log's When cell is the one place both readings appear: the
  absolute time leads in `.log-when-absolute`, because the row itself is
  evidence, and the relative reading follows it, because an admin scanning for
  what just happened asks for recency (#1632).  The absolute line is the
  **no-JS fallback for both**, so the relative span after it is seeded empty —
  seed both with the server string and the cell prints the same instant twice
  on every load before the script runs.  A hover `title` does not satisfy this: it is not a disclosure.

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
- **Interpolated class families** (`status-…`-style names built from
  enum values) are outside the grep's reach; they are pinned by
  `Tests/APITests/StatusClassStylesheetTests.swift`, which iterates the enum
  (`CaseIterable`) and asserts each minted selector exists.  A new
  interpolated family needs the same treatment.
- A class name a cross-page script depends on (e.g. `.error-message`, which
  `chickadee-ui.js` scrapes out of fetch bodies) lives in the global sheet
  with a comment naming the contract — never in a page block where a rename
  looks safe.
- **A modifier rule follows its base rule.** `.modal-card--confirm` and
  `.modal-card` are both one class, so the later rule wins on each property
  they share. A modifier placed above its base does nothing, and the page
  still renders. Guard 4d in `scripts/check-styles.sh` fails CI when a rule
  for `.x-mod` or `.x--mod` comes before a rule for `.x` that sets the same
  property, and both names occur on one line of a template or a script.
  Order decides only a tie: a more specific rule, such as
  `textarea.form-input`, wins whatever the order.

## Page-local scripts

Page behaviour belongs in a **`Public/*.js` file**, loaded with
`<script src>` — there it is ESLint-checked and unit-testable
(`Tests/BrowserRunnerJSTests`).  Inline `<script>` blocks in templates are
invisible to every tool (ESLint can't parse template-interpolated JS), so the
rule is **absolute** (the CSP forbids inline script, and the render test
fails on one): no page may open a multi-line `<script>` body.  The 2026-08
conversion moved every page's blocks out, and #1516 retired the last
holdout — the old base template's multipart-CSRF interceptor, now `/multipart-forms.js` — so the rule has no
allowed file and no ratchet.

The extraction pattern: the template carries page data — `data-*`
attributes or a **single-line** `<script type="application/json">` island —
and a per-page wiring file reads it (`assignment-edit-page.js` /
`assignment-new-page.js` are the worked examples: shared editor modules,
per-page URL builders).

Since #1516 this is no longer only a tooling rule.  The CSP `script-src`
carries no `'unsafe-inline'`, so **an inline script in a template does not
run** and **an `onclick=` / `onchange=` attribute never fires** — and
neither failure is loud: the control simply stops responding.  Two things
follow.

- A one-line `<script>` must be a **data** block.  Guard 3b skips one-line
  elements because that is the shape of the JSON islands; written without a
  `type`, the same shape is executed, slips past 3b, and is then blocked by
  the browser.  Guard 3b-2 catches it.
- An **event-handler attribute** is an inline script by another name, and the
  one shape a CSP nonce cannot rescue.  The replacement is a data attribute
  read by a delegated listener: `data-ck-click-target="<id>"`,
  `data-ck-submit-on-change`, and `data-ck-select-all` are the three the
  templates use, all handled in the declarative-control-behaviours block at
  the foot of `Public/app.js`.  Delegation also means markup rendered later —
  an in-place form swap, a row repainted by a poll — picks the behaviour up
  with no rebinding.  Guard 3b-3 catches a new one.

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
the greps cannot classify: computed geometry writes, `setProperty` calls on
ordinary properties, and `.style` reads.  It may only decrease.  A
custom-property write — `.style.setProperty('--…')` — is the sanctioned
pattern above and is not counted (`workbench.js`'s `--wb-left-width` and
`avatar-picker.js`'s live preview).

## Page-local styles

A page `<style>` block is for styling that genuinely exists on one page only.

- Class names are **role-named** (`.students-titlebar`), never
  utility-named (`.mt-1`, `.red-text`).
- A page block may not re-define a selector from the global sheet
  (`.main` is the one allowlisted override).
- No inline `style=""` except a JS-toggled `display:none` initial state or a
  **per-datum** custom-property assignment (`style="--bar-h:63%"`, a chart
  bar's height from the row being rendered).  A component's own token is
  **not** a per-page dial: `--filter-width` and `--form-stack-width` were
  both used as one and both drifted, so the guard now allows only the
  per-datum props it names.  A genuinely different width is the token's
  value or a named modifier class in `styles.css`.
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
6. `scripts/check-ui-vocabulary.sh` — the count of global classes this
   document does not name is a shrink-only ratchet, `cursor` and
   `text-decoration` values come from the affordance registry, and hover text
   in a template stays within 20 words.

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

The `ui-review` agent (`.claude/agents/ui-review.md`) reviews the layer
above the guards: a construct that duplicates the vocabulary under another
name, an idiom heavier than the cheapest that fits, copy over house length,
a page that steps outside its archetype.  Run it from a Claude Code session
on any change touching `Sources/APIServer/Views/`, `Public/styles.css` or a
page-wiring `Public/*.js`; CI runs the same brief on every such pull request
(`.github/workflows/ui-review.yml`) and fails the job on a `changes
requested` verdict.
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
  the component vocabulary above.  The note is not optional bookkeeping:
  `scripts/check-ui-vocabulary.sh` counts the classes in the global sheet
  this catalog does not name and fails on growth, so the entry is what pays
  for the component.  Before writing it, search the catalog for the
  *concept* — a duplicate arrives under a name that shares nothing with its
  twin, which is why the guard cannot find it for you.
- **New interaction idiom** (a `cursor`, a `text-decoration`, a way to
  reveal detail that is not in the table above) → this is a rulebook edit
  and a change to the affordance registry in that script, with the reasoning
  in the PR description.  Reach for it last: the table is ordered
  cheapest-first, and a fifth way to reveal detail makes the other four less
  meaningful.
- **New page** → pick an archetype, **copy its exemplar** from the table
  above, and strip it back to what the page needs.  Then assemble the rest
  from the vocabulary, and add the page to `Tools/visual-regression/pages.mjs`
  if it introduces a new shape (commit the CI bootstrap capture as its
  baseline in the same PR).  Copying beats generating: a `new-page.sh` that
  stamps out a skeleton would be a second source of truth, drifting from the
  exemplar the moment either changed.
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
