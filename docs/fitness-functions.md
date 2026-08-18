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
  (`app.routes.all`), substitutes real fixture IDs, and asserts every
  parameterized `/instructor` and `/courses` route denies a student of the
  owning course and staff of a different course. Route enumeration is
  discovered, so a new route the matrix does not know fails loudly.
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

## The gap worth acting on

**The route table is discovered. The role dimension is hand-listed.**

`RouteAuthorizationMatrixTests` crosses *every* route with exactly two
personas: a student of the owning course, and an instructor of a different
course. `CourseRole.allCases` is `student < ta < instructor`, and **`.ta`
appears zero times in that matrix.** The TA boundary — the rule that a TA may
author content and grade but may *not* manage enrollment, deadlines, archival
or staff — rests on eight hand-written spot tests in `TARoleRouteTests`.

So a new instructor-only route that forgets its `.instructor` floor passes both:
the matrix denies students and cross-course staff, and a TA of the owning course
is neither; the spot suite only covers routes someone remembered to add. That is
precisely the *"enumerated rather than discovered, fails open"* shape the
language work was built to escape — on the one dimension where the failure mode
is cross-course access to student data rather than a mis-rendered test.

**The fix is small, because both halves already exist**: the matrix already
discovers routes and already knows how to build enrolled personas. Crossing the
discovered route table with `CourseRole.allCases` — asserting each route's
declared floor rather than a fixed pair — turns eight remembered cases into a
derived matrix, and makes a new role (or a new route) fail loudly instead of
quietly.

Two smaller ones, recorded rather than argued:

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
