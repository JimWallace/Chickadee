# Fitness functions — what governs this codebase

An inventory of the automated checks that hold Chickadee's architecture, using
the vocabulary from [Building Evolutionary Architectures][beas]. Two reasons it
is worth writing down: the checks are spread across 31 scripts, ~333 Swift test
files, 51 docs and a dozen workflows, so nothing answers *"what governs this?"*
in one place; and the taxonomy sorts them in a way that makes a real gap
visible.

Nothing here is new machinery. Chickadee invented these independently and the
best of them are better articulated than the literature's examples — what the
vocabulary adds is a way to see which **kinds** are thin.

[beas]: https://nealford.com/books/buildingevolutionaryarchitectures.html

## The vocabulary, in one paragraph

A **fitness function** is an objective test of an architectural characteristic.
Two axes matter here. **Atomic** functions test one dimension in isolation; a
**holistic** one tests dimensions *interacting*, which is where defects
actually live once each part is individually correct. **Triggered** functions
run on an event — a commit, a PR; **continual** ones run against production
continuously.

## What Chickadee has

### Atomic + triggered — the bulk, and effectively airtight

The `scripts/check-*.sh` family (palette, type/radius/spacing scales, CSS var
resolution, class resolution, component vocabulary, maintenance-page palette,
vendored-kernel integrity, wasm size, version), the six shrink-only ratchets,
`no-language-defaults.sh`, `no-new-xctest.sh`, SwiftLint at `--strict`,
swift-format, ESLint, and most of the ~3,000 tests.

These carry a property most codebases' linters do not: **ratchets**, which
encode a *direction of travel* rather than a threshold. `PAGE_STYLE_BASELINE`
does not say page CSS must be under N lines; it says it may only shrink. That
is a fitness function over time, and it is why the widget-layer audit actually
converged.

As of #1448 they also have a self-test: `scripts/check-guards.sh` requires
every guard to be **seen to fail** on a fixture reproducing the defect it
exists to catch. A fitness function nobody has watched fail is a hypothesis.

### Holistic + triggered — fewer, and the best work here

- **`LanguageConformanceMatrixTests`** — every capability asserted for every
  `AssignmentLanguage.allCases`, with the per-language glue in one exhaustive
  switch so *the compiler produces the worklist*. Written because the previous
  test hand-listed `[.python, .r]` and would have silently kept testing two.
- **`LanguagePipelineWalkTests`** — one end-to-end walk per language along
  resolve → render family → render check → write inputs → normalize notebook,
  asserting each stage against the language **the first step resolved**. Its
  header states the holistic case exactly: *"every defect sat in the JOINT
  between stages, where something asked 'which language is this?' and answered
  Python."*
- **`RouteAuthorizationMatrixTests`** — walks the *live route table*
  (`app.routes.all`), substitutes real fixture IDs, and crosses every
  parameterized `/instructor` and `/courses` route with two dimensions: course
  identity (staff of a *different* course are denied everywhere) and role rank
  (each route's declared floor, crossed with `CourseRole.allCases`). Both are
  discovered — a new route the matrix does not know fails loudly, a new route
  with no declared floor fails until someone declares it, and a new role rung
  gets its denial row with no edit to the test.
- **`MCPAuthorizationCoverageTests`** — scans every tool's source and fails the
  build if one skips authorization.
- **`Tools/visual-regression/run-repaint-probe.sh`** — the seam where the
  shared filter, sort, poll and icon sprite meet, which a screenshot cannot
  catch because both sides would agree.
- The editor and browser-grading smokes, which boot real kernels because
  *"only a real kernel proves any of this."*

### Continual — present, but not treated as fitness functions

- The `chickadee-deployer` daemon health-gates each blue-green cutover and
  **auto-rolls-back if the new version degrades**. That is a continual fitness
  function in the literal sense: a production measurement with an automated
  corrective action.
- `get_health_alerts`, the queue/runner/metrics surface, and the browser
  diagnostics table are continual measurements.

The gap is not that these are missing — it is that they are **operational
plumbing rather than governed invariants**. No document states what degradation
triggers a rollback, nobody reviews the thresholds when the system changes, and
they are not in any list of things that hold the architecture. Compare the
triggered side, where every rule has a named guard, a baseline, and a doc.

## The gap worth acting on — **closed (2026-08)**

The finding was: **the route table is discovered, the role dimension is
hand-listed.** `RouteAuthorizationMatrixTests` crossed *every* route with
exactly two personas — a student of the owning course and an instructor of a
different course — so `.ta` appeared nowhere in it, and the TA boundary rested
on eight hand-written spot tests in `TARoleRouteTests`. An instructor-only route
that forgot its `.instructor` floor passed both, because a TA of the owning
course is neither persona and the spot suite only covered routes someone
remembered to write. That was the *"enumerated rather than discovered, fails
open"* shape the language work was built to escape, on the dimension where the
failure mode is access to another course's student data.

What shipped, and the three things worth keeping from doing it:

- **The floor is declared, not scanned.** Inferring each route's floor from its
  handler — grepping for `requireCourseRole(atLeast:)` — was the tempting cheap
  option and is the one that fails open: a route whose gate is spelled
  differently, or missing entirely, reads as having no floor and passes. The
  floor is a judgement about what the route *is*, so it is written down once and
  the code is held to it. The discovered route table keeps the map honest — a
  walked route with no entry fails by name.
- **It found a real defect on its first run.** Course-section create / rename /
  reorder / delete and assignment-to-section moves enforced nothing beyond the
  `/instructor` area gate, so any TA could restructure a course — while the MCP
  twins enforced `.instructor` and their own comments claimed to be "matching
  the web". Three documented statements of the floor, no enforcement, and every
  existing test green: exactly the miss a derived matrix exists to catch.
- **The positive direction needed its own discipline.** "Not denied" is a weak
  assertion that passes on an unrelated 404, and an allowed request *runs* —
  measured, `POST /instructor/:assignmentID/delete` succeeds mid-walk and every
  later `:assignmentID` route 404s, so a naive walk reads its own exhaust. The
  fix was to re-mint the target resources before each allowed probe and to
  enumerate the routes that still 404 an authorized caller, rather than
  tolerating 404 everywhere.

Two smaller gaps remain, recorded rather than argued:

- **No holistic function covers `MCPMode × scope × tool`.** The pieces are
  guarded individually (`MCPModeScopeContractTests`, `MCPConfigTests`,
  `MCPAuthorizationCoverageTests`); the product is not walked.
- **The continual functions have no stated contract.** Writing down what the
  deployer treats as degradation, and reviewing it when the system changes,
  would make it a governed invariant rather than a script's default.

## The rule this suggests

The language dimension got a matrix and a walk because it hurt repeatedly. That
is the honest history — these were bought with pain, not foresight. The cheap
generalization: **when a dimension is enumerable (`allCases`) and crosses more
than two subsystems, derive the matrix rather than remembering the cases.** The
compiler produces the worklist; the matrix produces the definition of done.

Everything else in this document is inventory. That sentence is the finding.
