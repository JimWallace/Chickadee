### Added

- **The UI rulebook now covers which interaction to reach for, and how much
  text it may carry — and CI enforces the mechanical half.**
  `scripts/check-ui-vocabulary.sh` joins the `format-lint` job with three
  rules. The count of classes in `Public/styles.css` that
  `docs/ui-design.md` does not name is a **shrink-only ratchet**, so a new
  global component costs a catalog entry, paid in the PR that adds it: the
  page-style ratchet already priced a page-local copy, but the global sheet
  carried no budget at all, which made "put it in `styles.css`" the cheapest
  way to add a second spelling of an existing component. `cursor` and
  `text-decoration` values are a closed **affordance registry** — adding a way
  to signal that an element is interactive is now a rulebook edit rather than
  a line in a rule body. Hover text written in a template is capped at 20
  words. `docs/ui-design.md` gains the two sections it never had: an
  **interaction-idiom** table (cheapest first: on the page → `<details>` →
  row-anchored popover → modal) and a **UI copy** budget, whose rule is that
  anything longer than a phrase belongs in `docs/` with the interface linking
  to it. A `ui-review` agent covers the judgement the guards cannot reach.
  The catalog debt this exposed was paid down in the same pass: the shorthand
  the doc used for component families (`.modal-head/-body/-foot`) is spelled
  out so the names are greppable, and the site navigation and the
  drag-to-reorder vocabulary — one grip, one in-flight class, one set of drop
  cues, shared across the two reorder surfaces — are catalogued for the first
  time. There is no dead CSS to remove: every rule in the global sheet is
  reached by a template, by page JS, by a Leaf-interpolated class family, or
  by the vendored CodeMirror bundle.

### Changed

- **The per-student dataset estimates are plain chips.** They shipped as a
  private variant with a dotted underline and `cursor: help`, carrying
  50-word explanatory paragraphs in their hover titles — a fifth way to reveal
  detail in a UI that had four, and a second kind of chip beside `.chip`,
  which every guard passed. They now use `.chip`/`.chip-row`, each title is a
  phrase naming what its number measures, and the method they used to explain
  is in `docs/datasets.md`. Three over-long hover titles elsewhere (the
  no-runner and failed-variant badges, the default time limit) were cut to a
  sentence, and the "no runner" badge — the one validation state whose only
  remedy lived in a tooltip — gains the same on-page follow-up line its
  `failed` and `pending` siblings already had. A hover title assembled from an
  instructor's own column names and category values is now bounded to a
  fixed number of words, so a course whose stratum is "Type 2 Diabetes"
  cannot silently breach the budget the same release introduced. The numbers,
  and the thirteen components that had reached `styles.css` without ever
  reaching the catalog, are unchanged and now documented.
