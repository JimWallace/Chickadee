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

## Component vocabulary

Reuse before you restyle.  The global sheet already has:

- **`.btn`**, `.btn-primary`, `.btn-danger` — buttons.
- **`.form`**, `.form--wide`, `.form-input`, `.form-error` — forms and the
  inline error banner (never native `alert()`).
- **`.flash`** + `.flash-success` / `.flash-error` / `.flash-neutral` —
  one-shot status banners after a POST-redirect.  Pair with `role="status"`
  (success/neutral) or `role="alert"` (error).
- **`.results-table`**, `.section-block` — the standard table/section layout.
- Badges/pills: `.achievement-badge`, tier and status badges.

If two pages need the same rule, it belongs in `Public/styles.css`, not
copied into both `<style>` blocks — the duplicate-selector guard fails CI on
copies.

## Page-local scripts

Page behaviour belongs in a **`Public/*.js` file**, loaded with
`<script src>` — there it is ESLint-checked and unit-testable
(`Tests/BrowserRunnerJSTests`).  Inline `<script>` blocks in templates are
invisible to every tool (ESLint can't parse Leaf-interpolated JS) and are
why the CSP still allows inline script, so their total size is a
**shrink-only ratchet** (`INLINE_SCRIPT_BASELINE` in
`scripts/check-styles.sh`): new inline lines fail CI.

The extraction pattern: the template carries page data — `data-*`
attributes or a `<script type="application/json">` island — and the
external file reads it.  When you shrink or extract a block, lower the
baseline in the same PR.

## Page-local styles

A page `<style>` block is for styling that genuinely exists on one page only.

- Class names are **role-named** (`.retention-intro`, `.learn-flag`), never
  utility-named (`.mt-1`, `.red-text`).
- A page block may not re-define a selector from the global sheet
  (`.main` is the one allowlisted override).
- No inline `style=""` except a JS-toggled `display:none` initial state or a
  custom-property assignment (`style="--filter-width:220px"`).
- Values inside page blocks follow the same token rules as the global sheet.

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
3. Inline-style allowlist, `alert()` ratchet, duplicate/shadowed-selector
   guards.

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
(`Tools/visual-regression/run-visual.sh --update`) in the same PR.

## Extending the system

- **New colour** → add the token pair to both `:root` blocks, then use
  `var(--x)`.
- **New size that truly fits no step** → change the scale in `styles.css`
  and this doc in the same PR, with the reasoning in the PR description.
  A scale with exceptions is just the old sprawl with extra steps.
- **New repeated pattern** (a third page grows the same card/banner/table
  flavour) → hoist it into `styles.css` as a named component and note it in
  the component vocabulary above.
- **Shrinking the spacing lattice** → when a step's last usage disappears,
  remove it from `SPACING_STEPS` in `scripts/check-design-tokens.sh` in the
  same PR.
- **Future ratchets** (candidates, not yet enforced): `font-weight` and
  `line-height` scales, and a size ratchet on page `<style>` blocks (a
  growing block is usually a component that wants hoisting).
