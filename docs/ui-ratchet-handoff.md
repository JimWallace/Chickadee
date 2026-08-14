# UI ratchet — instructions for the next pass (2026-08, rev 2)

You are continuing a multi-pass effort to make Chickadee's web UI consistent
and maintainable. Two passes are complete: the widget-layer audit
([ui-consistency-audit.md](ui-consistency-audit.md), shipped as S0–S10) and
the editor-surface pass (branch `claude/ui-ratchet-consistency-xc5wbn`, which
converted the assignment editors' JS-written styling to the shared `.cell-*` /
`.modal-*` / `.input-*` vocabulary, swept the editors' behaviour hooks to
`js-` names, and salvaged then closed PR #1384).

Read before acting: the **UI / Stylesheet Conventions** section of
`CLAUDE.md`, [ui-design.md](ui-design.md) (tokens, component vocabulary,
page archetypes, "JS does not make styling decisions"), and — before touching
either authoring template — [leaf-decomposition-review.md](leaf-decomposition-review.md).

Everything below is measured, not estimated. **Re-measure before you act**;
the commands are in "Verification" at the bottom.

---

## Where things stand

| ratchet | at audit | now | status |
|---|---:|---:|---|
| `INLINE_SCRIPT_BASELINE` | 1968 | **1317** | ← the remaining mass; P1 |
| `PAGE_STYLE_BASELINE` | 913 | **689** | shrink opportunistically; P3 |
| `JS_STYLE_DECISION_BASELINE` | 122 | **14** | **at its floor — done** |
| `ALERT_BASELINE` / `JS_ALERT_BASELINE` | 4 / 7 | **0 / 0** | absolute rules — done |
| axe moderate/minor | 12 | **0** | zero *on the 13 scanned pages*; P2 |
| class-resolution allowlist | 67 | **18** | fold into surface work; P3 |

Every ratchet sits exactly at its count, so any growth fails CI
(`scripts/check-styles.sh`, wired into the `format-lint` job).

`JS_STYLE_DECISION_BASELINE = 14` is a **floor, not a queue**: the count is
`app.js` popover geometry (8, the sanctioned runtime-computed use),
`chickadee-ui.js` flash/collapse behaviour plus a `--bar-h` custom-property
assignment the crude grep cannot tell from styling (4), `workbench.js`'s
`--wb-left-width` setProperty (1), and a `.style.fontSize` *read* (1).
Do not spend effort here.

---

## P1 — Extract the inline `<script>` blocks (the headline)

**Why this is the priority.** 1,317 lines of page JS live inside template
`<script>` blocks where no tool can see them — ESLint cannot parse
Leaf-interpolated JS, CodeQL skips it, nothing unit-tests it — and their
existence is **the reason the CSP still allows inline script**. The end state
worth aiming at: every page behaviour in a lintable `Public/*.js` file, pages
carrying only data (via `data-*` attributes or a
`<script type="application/json">` island), and then a CSP that drops the
inline-script allowance. That last step is a deliberate, separate change —
but every extraction is a prerequisite for it.

**The order, by measured size and by what else the extraction buys:**

| template | lines | notes |
|---|---:|---|
| `_assignment-edit-body.leaf` | 303 | do together with the next row |
| `assignment-new.leaf` | 258 | the create page has repeatedly been the **stale fork** of the edit page's JS — leaf-decomposition-review found three live defects that way. Extraction here is de-duplication: one shared `Public/*.js` file, two thin data islands |
| `admin.leaf` | 206 | admin dashboard |
| `assignments.leaf` | 200 | instructor dashboard |
| `instructor-brightspace.leaf` | 105 | |
| `instructor-students.leaf` | 100 | |
| `base.leaf` | 74 | **correct where it is** (bootstrap that must run before anything else); it is the last, hardest piece of any CSP flip — leave it for the CSP change itself |
| `admin-runner.leaf` + `assignment-submissions.leaf` | 71 | small; fold into a nearby slice |

**The extraction pattern** (established, do not invent a new one): the
template serialises page data into `data-*` attributes or a JSON island; the
new `Public/<page>.js` file reads it and owns all behaviour; the template
keeps a single `<script src="/<page>.js?v=#appVersion()">` line. Look at how
`suite-table.js` + `_suite-sections.leaf` or `global-inputs-editor.js` +
the global-inputs block do it. While extracting, give any behaviour-only
class hooks you touch the `js-` prefix (see P3) and add
`node --test`-able coverage for logic worth pinning — the point of the move
is that the code becomes testable.

**Slice it one template (or one create/edit pair) per PR.** Each PR lowers
`INLINE_SCRIPT_BASELINE` to the new count in the same commit.

**What NOT to do here:** do not build a shared Leaf partial for the two
authoring templates' *markup*. That has been litigated twice
(leaf-decomposition-review.md): the genuinely shared markup (~70 lines) is
already `_suite-sections.leaf`, and the rest differs structurally in ways a
shared partial would get subtly wrong. The JS is the safe, valuable half.

---

## P2 — Give the authoring surface the coverage it doesn't have

The previous pass discovered (the hard way — the prior handoff claimed
otherwise) that **neither authoring page is in the visual-regression capture
or the axe scan**. `Tools/visual-regression/pages.mjs` covers 13 pages, one
per archetype; the assignment edit page, the create page, and the workbench —
the most interaction-dense UI in the app, and the surface both prior passes
restyled — have only render tests, which prove templates resolve and nothing
else.

Work items, in order:

1. **Add an authoring-page capture to `pages.mjs`** (it feeds both the VR
   harness and the axe scan — one module, so both gain at once). Use the
   seeded instructor fixture; the page must render deterministically, so
   capture the assignment-edit page for a seeded assignment whose suite has
   at least one script row, one pattern family, and one notebook check (so
   the suite table, cell inputs, and validity-cue classes all render).
   Follow `seed.mjs`'s existing pattern. A page captured without a committed
   baseline bootstraps loudly — commit the CI capture in the same PR
   (CLAUDE.md, UI conventions).
2. **Check the axe results for the new page and drive them to zero** like
   S10 did for the original 13.
3. **Audit keyboard access on the editor interactions.** Drag-reorder (suite
   rows, sections), the Add Test modal (focus trap? Escape works — verify
   focus return), and the validity cues (are they colour-only, or does the
   title/text carry the information for a screen reader? — the cues set
   `title`, verify that is enough). Treat "axe = 0" as *unmeasured* for
   these interactions until this is done; axe cannot see drag-and-drop.
4. If mouse-only reordering turns out to be the only path, file the gap as
   an issue with a proposed keyboard affordance rather than bolting one on
   inside this pass.

**The one trap in this area** (it cost a day once): `run-visual.sh --update`
rewrites more captures than your change explains — run-to-run variance, not
real changes. After `--update`, `git status` the baselines and **revert every
capture your diff cannot explain**, then re-run the plain comparison. Green
with only the explainable captures updated is also your evidence the rest
was pixel-neutral.

---

## P3 — Ride-along work (never its own PR)

- **Page `<style>` blocks (689 lines).** No block dominates: `workbench.leaf`
  120, `_notebook-body.leaf` 59, `admin-mcp.leaf` / `admin-course.leaf` 52
  each, then a long tail. When a P1/P2 slice already has a template open,
  hoist what matches an existing component (the vocabulary list in
  `ui-design.md`) and lower `PAGE_STYLE_BASELINE` in the same PR. Do not
  open a template just to shrink its style block.
- **The 18-entry class-resolution allowlist.** All behaviour-only hooks on
  non-editor surfaces: `content-item-*` (6), assorted row/anchor hooks (10),
  `inplace-error-banner`, and the `sortable-table` opt-in marker. Rename to
  `js-*` when you touch their surface; delete the allowlist entry in the
  same PR (the guard fails on stale entries, so you cannot forget). Two
  lessons from the editor sweep: **ids are not class hooks** — do not rename
  `id="…"` values, and check every hit before a bulk rename (one token
  appeared as both a class and an id); a hook that is assigned but never
  queried anywhere is dead — delete it instead of renaming it.

---

## P4 — Deferred by design (do not start these; conditions to revisit)

- **Styled `<dialog>` confirmations / converging the two overlay
  implementations.** The `data-confirm` seam (app.js) and the S9 modal shell
  make this a one-place change whenever the native `confirm()` look is
  deemed not good enough. It is a product-taste call for the maintainer,
  not a blocked task.
- **S1b person typeahead** on the unified list filter. Deferred until the
  filter shows real usage. Nothing has changed.
- **The CSP inline-script flip itself.** Only after P1 reaches `base.leaf`.

---

## The contract (why the ratchets actually move — hold every slice to it)

1. **Lower the ratchet in the PR that earns it.** Headroom left behind gets
   spent by the next person adding a copy.
2. **Close the idiom, not just the instances.** When a conversion reaches
   zero, add the absolute guard (the editor pass removed the `el()` helpers'
   style parameter so a new call site *cannot* pass a style string — that
   shape, not just a lower number).
3. **Run** `scripts/check-styles.sh`, `scripts/eslint.sh`,
   `node --test Tests/BrowserRunnerJSTests/*.mjs`, and the render-test
   suites for every template you touched, before pushing.
4. **Watch your guard fail.** Add a violation, see the check go red, revert
   it. A check never seen to fail is not a check — the repaint probe's
   filter assertion once passed vacuously against a dead poll.
5. **Do not quote markup in comments or docs the guards scan.** A scanner
   cannot tell markup from prose about markup; this has bitten four times
   (the Leaf lexer #1266, the S5 guard, the icon sprite comment, and Leaf
   tag syntax in template comments). Describe the shape instead.

## Stop doing

- **Chasing `JS_STYLE_DECISION_BASELINE` below 14.** Floor. Converting the
  popover math or the custom-property writes trades blessed idioms for a
  rounder number.
- **Proposing a shared markup partial for create/edit.** Re-litigated twice;
  the answer is in leaf-decomposition-review.md.
- **Standalone rename/cleanup PRs.** The tails are ride-alongs now.
- **Adding new counters speculatively.** The guard set is dense and has its
  own failure modes (guards matching their own documentation, event-gated
  guards passing vacuously). Prefer an absolute rule when one is reachable;
  add a counter only for a named surface it will ratchet down.

---

## Verification

```
bash scripts/check-styles.sh
bash scripts/eslint.sh
node --test Tests/BrowserRunnerJSTests/*.mjs
```

Per-template inline-script and page-style counts (re-measure before slicing):

```
for f in Resources/Views/*.leaf; do n=$(awk '/<script[^>]*src=/ { next } /<script>/ && /<\/script>/ { next } /<script/ { inscript = 1; next } /<\/script>/ { inscript = 0; next } inscript && NF > 0 { n++ } END { print n + 0 }' "$f"); [ "$n" -gt 0 ] && echo "$n $(basename $f)"; done | sort -rn
```

```
for f in Resources/Views/*.leaf; do n=$(awk '/<style>/ { inblock = 1; next } /<\/style>/ { inblock = 0; next } inblock && NF > 0 { n++ } END { print n + 0 }' "$f"); [ "$n" -gt 0 ] && echo "$n $(basename $f)"; done | sort -rn
```

JS style decisions per file (should stay: app.js 8, chickadee-ui.js 4,
workbench.js 1, jl-cell-perf-patch.js 1):

```
for f in Public/*.js; do n=$( { grep -ho 'style="' "$f" || true; grep -hoE '\.style\.[a-zA-Z]+' "$f" | grep -v '\.style\.display' || true; grep -ho 'cssText' "$f" || true; } | wc -l); [ "$n" -gt 0 ] && echo "$n $f"; done | sort -rn
```
