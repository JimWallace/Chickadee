# UI ratchet — handoff for the next pass (2026-08)

The widget-layer audit ([ui-consistency-audit.md](ui-consistency-audit.md))
shipped as S0–S10 and is closed. **The editor-surface pass that this brief
originally queued as items 1–3 has since shipped too** (the pass that
converted the pattern-family editor, suite table, inputs editors, Test
Editor modal and both test renderers to the shared `.cell-*` / `.modal-*` /
`.input-*` vocabulary, swept the editors' hooks to `js-` names, and salvaged
then closed PR #1384). This brief is for whoever continues from there:
where the remaining mass actually sits, and the trap that will cost you a
day if you walk into it cold.

Everything below is measured, not estimated. Re-measure before you act —
the commands are given.

---

## Where things stand

| ratchet | at audit | now | headroom |
|---|---:|---:|---|
| `INLINE_SCRIPT_BASELINE` | 1968 | **1317** | none — sits at the count |
| `PAGE_STYLE_BASELINE` | 913 | **689** | none |
| `JS_STYLE_DECISION_BASELINE` | 122 | **14** | none — **at its floor** |
| `ALERT_BASELINE` | 4 | **0** | absolute |
| `JS_ALERT_BASELINE` | 7 | **0** | absolute |
| axe moderate/minor | 12 | **0** | absolute in practice |
| class-resolution allowlist | 67 | **18** | shrink-only |

Every ratchet is at its count, so *any* growth fails CI.

**`JS_STYLE_DECISION_BASELINE` = 14 is a floor, not a queue.** What the
count still sees is the sanctioned remainder — `app.js`'s runtime-computed
popover geometry (8), `chickadee-ui.js`'s flash colour, collapse-animation
overflow writes and a `--bar-h` custom-property assignment the crude grep
cannot tell from styling (4), `workbench.js`'s `--wb-left-width`
setProperty (1), and a `.style.fontSize` *read* in `jl-cell-perf-patch.js`
(1). Converting any of these would be fixing the counter, not the code.

**The 18-entry allowlist** is the non-editor tail: `content-item-*` (6),
assorted row/anchor hooks (10), `inplace-error-banner`, and the
`sortable-table` opt-in marker. Each is a rename of the same mechanical
shape as the editor sweep — worth folding into whatever pass next touches
its surface, not worth a pass of its own.

Reproduce:

```
bash scripts/check-styles.sh
```

```
for f in Public/*.js; do n=$( { grep -ho 'style="' "$f" || true; grep -hoE '\.style\.[a-zA-Z]+' "$f" | grep -v '\.style\.display' || true; grep -ho 'cssText' "$f" || true; } | wc -l); [ "$n" -gt 0 ] && echo "$n $f"; done | sort -rn
```

---

## Where the remaining mass sits

With the JS-styling ratchet at its floor, two ratchets hold everything
left, and both are template-side:

**`INLINE_SCRIPT_BASELINE` = 1317**, by template — the two authoring pages
are 44%:

| template | lines |
|---|---:|
| `_assignment-edit-body.leaf` | ~325 |
| `assignment-new.leaf` | ~254 |
| `admin.leaf` | 230 |
| `assignments.leaf` | 223 |
| `instructor-brightspace.leaf` | 116 |
| `instructor-students.leaf` | 111 |
| `base.leaf` | 77 — correct where it is |
| `admin-runner` + `assignment-submissions` | 77 |

The extraction pattern is established (data via `data-*`/JSON island, logic
in a lintable `Public/*.js`), and the editor-surface pass demonstrated the
adjacent cleanups pay for themselves: the create page's inline scripts were
repeatedly found to be the stale fork of the edit page's
(leaf-decomposition-review.md), so extraction is also de-duplication.

**`PAGE_STYLE_BASELINE` = 689** — page-local `<style>` blocks. No single
block dominates; shrink opportunistically when a page is already open.

---

## The trap

### Regenerating visual baselines rewrites more than you changed

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
  wrong is worse than two honest copies. Extracting their inline *scripts*
  to shared `Public/*.js` files is the safe half of that work — the review
  found the create page's inline JS was the *stale fork* every time it
  looked, and fixing three forks removed three live defects.
- **Converting the sanctioned JS `.style` remainder.** The 14 counted
  decisions left are popover geometry, custom-property writes and a read —
  the patterns `ui-design.md` explicitly blesses. Rewriting them to appease
  a grep would trade working idioms for a rounder number.
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
