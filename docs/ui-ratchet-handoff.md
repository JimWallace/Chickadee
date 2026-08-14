# UI ratchet — handoff for the next pass (2026-08)

The widget-layer audit ([ui-consistency-audit.md](ui-consistency-audit.md))
shipped as S0–S10 and is closed. This brief is for whoever continues the
ratchet: where the remaining mass actually sits, which of it is mechanical,
and the two traps that will cost you a day if you walk into them cold.

Everything below is measured against `main` at the close of S10, not
estimated. Re-measure before you act — the commands are given.

---

## Where things stand

| ratchet | at audit | now | headroom |
|---|---:|---:|---|
| `INLINE_SCRIPT_BASELINE` | 1968 | **1317** | none — sits at the count |
| `PAGE_STYLE_BASELINE` | 913 | **689** | none |
| `JS_STYLE_DECISION_BASELINE` | 122 | **118** | none |
| `ALERT_BASELINE` | 4 | **0** | absolute |
| `JS_ALERT_BASELINE` | 7 | **0** | absolute |
| axe moderate/minor | 12 | **0** | absolute in practice |
| class-resolution allowlist | — | **67** | shrink-only |

Every ratchet is at its count, so *any* growth fails CI. Five guards were
added by the audit; three are absolute rules rather than ratchets (icon
geometry outside the sprite, native confirmation outside the seam, the
retired button size modifiers).

---

## The headline: one surface owns almost everything that is left

The pattern-family / suite authoring surface is not merely *a* remaining
target — it dominates three of the four open ratchets at once.

**`JS_STYLE_DECISION_BASELINE` = 118**, by file:

| file | count | share |
|---|---:|---|
| `pattern-family-editor.js` | 54 | 46% |
| `suite-table.js` | 22 | 19% |
| `test-editor-modal.js` | 12 | |
| `inputs-editor-core.js` | 12 | |
| `app.js` | 8 | |
| everything else | 10 | |

Two files are **64%** of it.

**`INLINE_SCRIPT_BASELINE` = 1317**, by template — the two authoring pages
are 44%:

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

**The 67-entry class-resolution allowlist**, by owning surface: `pf-*` 13,
`section-*` 11, `suite-*` 9, `global-input-*` 5, `am-*` 3, `ach-*` 2 —
43 of 67 from the same editors.

Reproduce all three:

```
bash scripts/check-styles.sh
```

```
for f in Public/*.js; do n=$( { grep -ho 'style="' "$f" || true; grep -hoE '\.style\.[a-zA-Z]+' "$f" | grep -v '\.style\.display' || true; grep -ho 'cssText' "$f" || true; } | wc -l); [ "$n" -gt 0 ] && echo "$n $f"; done | sort -rn
```

---

## Low-hanging fruit, in the order I would take it

### 1. `pattern-family-editor.js` cell styling — the single best ratio

54 of 118 JS style decisions, and they are **repeated literals**, not
per-case logic. The same string recurs across the case-table builders:

```
style="width:100%;padding:.2rem .4rem;font-size:.8rem;font-family:monospace"
```

Three or four shared classes absorb nearly all of it: a table-cell input, a
narrow column, a muted inline note, a compact remove button.

This is also a **token-layer** fix, not only a ratchet fix. Those literals
bypass the scales the CSS guards enforce: `font-size:.7rem` is not a step
(`--text-2xs` is `.72rem`), and bare `font-family:monospace` is exactly what
`ui-design.md` forbids in favour of `--font-mono`. The guards cannot see any
of it because it lives in a JS string.

Note 25 of the 30 `borderColor`/`color` writes in the whole codebase are in
this one file — validity cues that want toggled classes with dark-mode
values, since a hardcoded colour here is invisible-on-dark waiting to happen.

**Expected:** `JS_STYLE_DECISION_BASELINE` 118 → roughly 60. Low risk: it is
one file, covered by frontend tests, and the visual harness captures the
pages it renders.

### 2. `suite-table.js` — the same job, 22 more

Same shape, same fix, and it shares the `suite-*` allowlist entries. Doing it
right after (1) means the classes from (1) already exist.

### 3. The `js-` prefix sweep — mechanical, shrinks a third ratchet

The 67 allowlist entries are behaviour-only hooks predating the convention.
Renaming `pf-case-remove` → `js-pf-case-remove` (and its JS selector) removes
an entry with no styling risk. 43 belong to the two files above, so fold this
into (1) and (2) rather than doing it as its own pass.

**Do not** add allowlist entries. It is shrink-only by contract.

---

## The two traps

### Trap 1: PR #1384 is stale and half-superseded. Do not just rebase it.

`claude/ui-rendering-rules-al968b`, open draft, based on `ad9e84b` — which
predates the entire S0–S10 series. Its **CSS-vocabulary half was independently
redone** by S7/S7b, in some cases differently:

| #1384 proposed | status now |
|---|---|
| `.bs-*` → global vocabulary | **done in S7b** (`.bs-status` → `.detail-grid`; the green/red pairs → `.chip-ok`/`.chip-err`) |
| `.storage-bar` → `.page-titlebar--baseline` | **done in S7b** |
| `.titlebar-subtitle` | **done in S7** |
| `.popover-panel` | **done in S7** |
| VR determinism / relative-time pinning | **done differently** — `capture.mjs` freezes the masked text |
| `.editor-modal-*`, `.input-expression` / `-attention` / `-invalid`, `.editor-stack`, `.editor-cm-mount`, `.input-mono` | **still unique — this is the valuable part** |

Its ratchet numbers are also wrong now: it claims 913 → 811 and 122 → 100,
against actual 689 and 118.

**Recommendation:** do not rebase it wholesale. Salvage the JS-styling half
(which overlaps items 1–2 above and is the same work), and close it with a
note rather than fighting the conflicts. Verify before trusting this table:

```
for c in editor-modal input-expression editor-cm-mount input-mono titlebar-subtitle popover-panel chip-ok; do grep -q "\.$c" Public/styles.css && echo "$c PRESENT" || echo "$c absent"; done
```

### Trap 2: regenerating visual baselines rewrites more than you changed

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
