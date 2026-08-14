# UI ratchet — the maintainability epic, closed (2026-08)

**This epic is complete.** The widget-layer audit
([ui-consistency-audit.md](ui-consistency-audit.md)) shipped as S0–S10; the
editor-conversion pass and the inline-script pass (both 2026-08-14) closed
the two big tracks it left open; the tail pass closed the allowlist. This
document is now the closure record plus the standing rules for what comes
next. Nothing here is a work list any more — per-page revision work starts
from ["For the per-page revision work"](#for-the-per-page-revision-work) at
the bottom.

Everything below is measured, not estimated. Re-measure before trusting a
number that gates a decision — the commands are given.

> **Update (2026-08, the inline-script pass): the inline-script track is
> complete.** Every template's multi-line `<script>` body moved into a
> `Public/*.js` file — seven page-wiring files plus the shared
> `support-files.js` (the upload/delete flow both authoring pages had
> forked) — and guard 3b became an **absolute rule**: no template may open
> a multi-line inline script, except `base.leaf`'s multipart-CSRF
> interceptor, which stays by design under its own shrink-only ratchet
> (`INLINE_SCRIPT_BASELINE=74`). Two findings from the conversion worth
> knowing: the old counter's single-line rule did not recognise the JSON
> seed islands (attributes defeated its `<script>` match), so the historic
> 1317 included template prose the leaked state swallowed — the corrected
> counter is in guard 3b; and the `.suite-edit-upload-btn` wiring on the
> edit page was dead (nothing renders that class since the per-script
> upload flow), with its Swift regression test passing vacuously by
> matching the wiring string in the page HTML.

---

## Where things stand

| ratchet | at audit | now | headroom |
|---|---:|---:|---|
| `INLINE_SCRIPT_BASELINE` | 1968 | **74** (base.leaf only; rule absolute elsewhere) | none |
| `PAGE_STYLE_BASELINE` | 913 | **689** | none |
| `JS_STYLE_DECISION_BASELINE` | 122 | **10** | none — see below |
| `ALERT_BASELINE` | 4 | **0** | absolute |
| `JS_ALERT_BASELINE` | 7 | **0** | absolute |
| axe moderate/minor | 12 | **0** | absolute in practice |
| class-resolution allowlist | 67 | **1** | `sortable-table`, the documented exception |

Every ratchet is at its count, so *any* growth fails CI. The audit's three
absolute rules (icon geometry outside the sprite, native confirmation
outside the seam, the retired button size modifiers) have gained three
more: the editor pass made colour/typography `.style` writes and
non-custom-prop `style="…"` strings in `Public/*.js` absolute (check-styles
3d/3e), and the inline-script pass made guard 3b absolute (the note above).

The remaining 10 styling-decision counts are the residue the greps cannot
classify — computed geometry in `app.js` (5), the collapse-animation
overflow toggles and the compliant `--bar-h` meter in `chickadee-ui.js`
(3), `workbench.js`'s sanctioned `setProperty` (1), and a `.style.fontSize`
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

A merge lesson from the two passes landing the same day: the hook renames
and the script externalization compose only if the externalized wiring
files adopt the renames — three freshly-moved `querySelector`s still said
`.section-edit-toggle` while the markup said `js-section-edit-toggle`, a
breakage no guard sees because the resolution check reads assignments, not
queries. When a rename pass and a move pass cross, grep the moved files
for the old names before trusting a green merge.

Reproduce the measurements:

```
bash scripts/check-styles.sh
```

```
for f in Public/*.js; do n=$( { grep -ho 'style="' "$f" || true; grep -hoE '\.style\.[a-zA-Z]+' "$f" | grep -v '\.style\.display' || true; grep -ho 'cssText' "$f" || true; } | wc -l); [ "$n" -gt 0 ] && echo "$n $f"; done | sort -rn
```

---

## The tail pass (closed the epic)

The last 21 removable allowlist entries went in the final pass, each by
what it actually was rather than by blanket rename:

- **10 hooks JS genuinely reads** took the `js-` prefix
  (`js-check-edit-btn`/`-delete-btn`, `js-family-edit-btn`/`-delete-btn`,
  `js-support-file-delete-btn`, `js-publish-due-date`, `js-nb-fallback`,
  `js-subm-trend-spark`, `js-bs-grade-id-hidden`,
  `js-inplace-error-banner`), renamed at every assignment and query site.
- **11 tokens nothing read or styled were dropped outright** — the
  `content-item-*` six, `role-cell`, `role-fixed`, `slip-day-summary`,
  `submission-actions`, `tier-secret-badge`. Each was verified unread
  (including dynamically-built selectors) and unstyled before removal;
  they were leftovers of earlier eras doing literally nothing.
- **`sortable-table` stays, deliberately**, as the allowlist's single
  documented entry: it is the sort component's opt-in marker, renaming it
  would churn every sortable table for zero drift risk, and a stylesheet
  rule for it would be a lie (it opts into behaviour, not appearance).

`PAGE_STYLE_BASELINE` (689) never had a slice plan and does not need one:
it shrinks opportunistically when a page block's pattern is promoted into
the component vocabulary during page revisions.

### Historical: where the inline-script mass sat

The per-template counts of the retired 1317-line baseline, kept because
they say where each page's wiring file came from:

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
  Start with the JS. *(Done: the JS lives in `assignment-edit-page.js` /
  `assignment-new-page.js` plus the shared `support-files.js`; the markup
  stays two honest copies, and the judgement above still holds for it.)*
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

---

## For the per-page revision work

The epic's end state is the starting contract for revising individual
pages. In practice it means:

- **The rulebook is [ui-design.md](ui-design.md)**, and it is enforced, not
  aspirational: tokens (palette/type/radius/spacing), the component
  vocabulary, the page archetypes, `js-` hooks, class resolution, and the
  absolute rules (no alerts, no raw confirm, no icon geometry outside the
  sprite, no inline template script, no JS-written colour/typography, no
  non-custom-prop `style=` anywhere). A revision that fights the guards is
  wrong by definition — extend the vocabulary instead, in `styles.css`,
  with the ui-design.md catalog updated in the same PR.
- **Every page's behaviour lives in a lintable, testable wiring file**
  (`Public/<page>.js`), and its styling in named classes. Redesigning a
  page means editing exactly those two layers plus the template's markup —
  there is no third place for logic or appearance to hide any more.
- **Budgets are spent, not banked.** Ratchets sit at their counts; a page
  revision that adds a page-local `<style>` line must remove one somewhere
  (or promote the pattern to the global sheet). That is intentional
  pressure toward the vocabulary.
- **Evidence over eyeballs:** a page revision changes pixels on purpose, so
  its PR regenerates the affected visual baselines (Trap 2's rule: revert
  every capture the diff cannot explain) and keeps axe at zero. New
  interactive seams deserve a repaint-probe assertion, not just a
  screenshot.
- **The per-page fine-tuning epic should keep this file closed.** New
  systemic debt goes in a new document against a new audit — this one
  records where the maintainability line was drawn and why.
