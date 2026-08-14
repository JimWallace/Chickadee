# UI ratchet — handoff for the next pass (2026-08)

The widget-layer audit ([ui-consistency-audit.md](ui-consistency-audit.md))
shipped as S0–S10 and is closed. This brief is for whoever continues the
ratchet: where the remaining mass actually sits, which of it is mechanical,
and the traps that will cost you a day if you walk into them cold.

**Updated after the editor-conversion pass (2026-08-14),** which took the
brief's items 1–3 and the #1384 salvage in one PR. Everything below is
measured, not estimated. Re-measure before you act — the commands are given.

---

## Where things stand

| ratchet | at audit | now | headroom |
|---|---:|---:|---|
| `INLINE_SCRIPT_BASELINE` | 1968 | **1317** | none — sits at the count |
| `PAGE_STYLE_BASELINE` | 913 | **689** | none |
| `JS_STYLE_DECISION_BASELINE` | 122 | **10** | none — see below |
| `ALERT_BASELINE` | 4 | **0** | absolute |
| `JS_ALERT_BASELINE` | 7 | **0** | absolute |
| axe moderate/minor | 12 | **0** | absolute in practice |
| class-resolution allowlist | 67 | **22** | shrink-only |

Every ratchet is at its count, so *any* growth fails CI. Two more idioms
became **absolute rules** in the editor pass (check-styles 3d/3e): no
colour/typography property written via `.style` in `Public/*.js`, and no
`style="…"` in a JS-built HTML string beyond a custom-prop or
`display:none`. The remaining 10 ratchet counts are the residue the greps
cannot classify — computed geometry in `app.js` (5), the collapse-animation
overflow toggles and the compliant `--bar-h` meter in `chickadee-ui.js` (3),
`workbench.js`'s sanctioned `setProperty` (1), and a `.style.fontSize`
*read* in `jl-cell-perf-patch.js` (1). Do not chase these; they are the
pattern, not the problem.

## What the editor pass closed (was items 1–3 of this brief)

The pattern-family / suite authoring surface owned 64% of the JS-styling
ratchet and 43 of the 67 allowlist entries. All of it is converted:

- `pattern-family-editor.js` (54 → 0), `suite-table.js` (22 → 0),
  `test-editor-modal.js` (12 → 0), `inputs-editor-core.js` (12 → 0), the
  two `test-renderer-*.js` (4 → 0), plus `setStatus`'s colour write in
  `chickadee-ui.js` and the static half of `app.js`'s popover float (now on
  `.is-floating`).
- The vocabulary they now share is in `styles.css` and the ui-design.md
  catalog: `.cell-input` (+ `--with-check`), `.input-mono`,
  `.points-input`, `.suite-name-input`, the `.input-*` value-state cues,
  the `.modal-*` shell family, `.editor-stack`, `.editor-cm-mount`,
  `.cell-stack`/`.cell-title`, `.field-help`, `.text-error/-ok/-quiet`.
- The inputs editors' JS-built rows now carry the same classes as the
  server-rendered template rows, which removed real drift (a `.95rem` vs
  `1rem` validity check, a `.78rem` vs `.8rem` input font).
- The `js-` sweep renamed every behaviour-only hook the editors owned
  (`js-pf-case-*`, `js-suite-*`, `js-section-*`, `js-global-input*`,
  `js-am-*`, `js-ach-*`); `pf-case-num`, `pf-var-row-valid` and
  `pf-var-section-row` gained stylesheet rules instead (they carried real
  styling). Three dead tokens were dropped outright (`pf-case-expected-col`,
  `am-conditions-wrap`, the `assignments-body` class).

Reproduce the measurements:

```
bash scripts/check-styles.sh
```

```
for f in Public/*.js; do n=$( { grep -ho 'style="' "$f" || true; grep -hoE '\.style\.[a-zA-Z]+' "$f" | grep -v '\.style\.display' || true; grep -ho 'cssText' "$f" || true; } | wc -l); [ "$n" -gt 0 ] && echo "$n $f"; done | sort -rn
```

---

## What is actually left, in the order I would take it

### 1. `INLINE_SCRIPT_BASELINE` = 1317 — now the only big number

By template, the two authoring pages are 44%:

| template | lines |
|---|---:|
| `_assignment-edit-body.leaf` | 325 |
| `assignment-new.leaf` | 254 |
| `admin.leaf` | 230 |
| `assignments.leaf` | 223 |
| `instructor-brightspace.leaf` | 116 |
| `instructor-students.leaf` | 111 |
| `base.leaf` | 77 — correct where it is |
| `admin-runner` + `assignment-submissions` | 77 |

Extraction is the `data-*`/JSON-island pattern (ui-design.md "Page-local
scripts"). Take one template per PR; lower the baseline in the same PR.

### 2. The 22 remaining allowlist entries

`content-item-*` (6, course-content editor), the cross-page row/anchor
hooks (14), `inplace-error-banner`, and `sortable-table`. All are the same
mechanical rename — the reason they are second is only that they spread
across more templates per name than the editor hooks did. `sortable-table`
is the one to leave: it is the opt-in marker the sort component documents,
so renaming it would churn every sortable table for zero drift risk.

---

## The traps

### Trap 1 (RESOLVED): PR #1384

Salvaged and closed by the editor pass. Its inputs-editor/value-cue half
landed (as `.input-expression`/`-attention`/`-invalid`, `.input-mono`,
`.editor-stack`, `.editor-cm-mount`); its modal vocabulary landed under the
S9 `.modal-*` names rather than its `.editor-modal-*` ones; its CSS half
was already done by S7/S7b. Nothing left to mine there.

### Trap 2 (still live): regenerating visual baselines rewrites more than you changed

`run-visual.sh --update` rewrote **12** captures for a change touching five
templates that cannot affect `login`, `student-submit`, `student-dashboard`
or `submission-pending`. Those extra ones are this environment's run-to-run
variance, not real changes, and committing them fails CI against the
canonical set.

**Rule:** after `--update`, `git status` the baselines and revert every page
your diff cannot explain. Then re-run the plain comparison. If it is green
with only the explainable captures updated, that is *also* your evidence the
rest of the change was pixel-neutral.

---

## What is deliberately not on the list

- **The two authoring templates' markup.** They are 44% of the inline-script
  ratchet and the biggest number on the board, but `leaf-decomposition-review.md`
  is right that a shared partial getting the create-vs-edit differences subtly
  wrong is worse than two honest copies. **Their JS is a different question
  from their markup** — that review found the create page was the *stale fork*
  every time it looked, and fixing three forks removed three live defects.
  Start with the JS.
- **S1b person typeahead.** Deferred until the unified filter has real usage.
  Still the right call; nothing has changed.
- **Styled `<dialog>` confirmations and converging the two overlays.** The
  `data-confirm` seam makes this a one-place change whenever it is wanted.
  No pressure to do it now.

---

## Before you ship anything

The contract every slice held to, and the reason the ratchets actually moved:

1. **Lower the ratchet in the PR that earns it.** Headroom left behind gets
   spent by the next person adding a copy.
2. **Add the guard that closes the idiom**, not just the instances. Prefer an
   absolute rule when the conversion reaches zero in one pass.
3. **Run** `scripts/check-styles.sh`, the affected render tests, and the JS
   gate (`scripts/eslint.sh`, `node --test Tests/BrowserRunnerJSTests/*.mjs`).
4. **Watch your guard fail.** A check never seen to fail is not a check. The
   repaint probe's own filter assertion was passing *vacuously* against a dead
   poll until it was tested that way — it read as coverage while proving
   nothing.
5. **Do not quote markup in a comment.** A scanner cannot tell markup from
   prose about markup. This has now bitten three separate times (#1266's Leaf
   lexer, the S5 guard failing on its own documentation, and the icon sprite's
   comment registering as a phantom call site). Describe the shape instead.

`Tools/visual-regression/run-repaint-probe.sh` runs in CI as a step of the
`visual` job and covers the seam where the shared filter, sort, poll and icon
sprite meet — the interactions that fail silently and that a screenshot
comparison cannot catch, because both sides would agree.
