# Datasets & living databases in assignments — design

A design note for two new authoring concepts in Chickadee, motivated by
HLTH 230 (Introduction to Health Informatics) and the desire to build
assignments where students **query data to solve a problem** rather than
just write standalone functions.

Status: **shipped** (all three waves; this document is the design record).

---

## Motivation

Two existing HLTH 230 assignments bracket where we are today:

- **Assignment 4** (`J9L7x8`) ships a static clinical CSV
  (`assignment4_vitaldb_cases.csv`, VitalDB perioperative cases) as a
  *support file* and grades exploratory analysis with notebook checks
  (`df` is a `DataFrame`, expected columns present, ≥2 figures, uses
  `describe()` / `groupby()`). The "dataset" is a file checked into the
  test-setup zip.
- **The Outbreak Investigation practice lab** (`jc56o4`) tells a 10-stage
  narrative ("Intake desk" → "The outbreak report") but mechanically it is
  a sequence of pure-function pattern families (`to_celsius`,
  `is_confirmed`, `positivity_rate`, `outbreak_summary`…). The "data" lives
  as literals inside the test cases.

Neither lets a student **interrogate a body of records** — issue a query,
look at what comes back, follow the thread, and reach a conclusion. That is
the experience we want: a student investigating a *living* dataset (an
outbreak, a drug-interaction signal, a billing-fraud pattern, a patient's
tangled history) where the answer is discovered, not computed from a
formula — and ideally where **every student gets a different mystery**, so
the work is genuinely their own.

This note proposes two layers:

1. **Datasets** — a first-class, instructor-hosted, versioned static-data
   artifact, attachable to many assignments, sliceable per student. This
   generalizes "a CSV in the zip."
2. **Databases** — a thin, in-process query/simulation layer *on top of* a
   dataset that makes it *feel* like a live database or clinical system the
   student queries, without ever being a network service.

---

## The constraint that shapes everything: no network at grade time

Chickadee grades student code in a deliberately air-gapped environment.
This is not incidental; it is the core of the security model, and it is the
single fact that decides the architecture below.

- **Worker path** (`Sources/Worker/SandboxedScriptRunner.swift`): on Linux,
  test scripts run under `unshare --user --net` — a private network
  namespace with **no outbound connectivity**. On macOS, `sandbox-exec`
  enforces `(deny network* (remote ip))`. Student code cannot open a socket.
- **Browser path** (Pyodide): the CSP is `connect-src 'self'`
  (`SecurityHeadersMiddleware.swift`), so in-browser student code can reach
  **same-origin endpoints only** — nothing external.

**Consequence:** "host an HL7/FHIR server and let students query it during
grading" is a non-starter against the worker, and browser-only and CSP-bound
against Pyodide. A real external server (HAPI FHIR + Synthea, a public FHIR
sandbox, etc.) remains a fine tool for *interactive exploration on the
student's own machine*, but it cannot participate in autograding.

So both layers below are built to run **in-process, from local files**, with
no network — and to work under **both** grading paths (worker `python3` and
in-browser Pyodide), or to be explicitly scoped to one with a stated reason.

---

## What we reuse

The good news: almost every primitive we need already exists. The two new
concepts are mostly *new payloads pointed at existing machinery*.

| Need | Existing mechanism |
|------|--------------------|
| Ship data into the grading workspace | Support-file extraction to `shared/{setupID}/` (worker) and into the Pyodide FS alongside the test-setup zip (browser, `BrowserRunnerRoutes`) |
| Per-student variation, deterministic & server-side | `CHICKADEE_ASSIGNMENT_SEED` (64-hex per `(student, assignment)`), `PersonalizationEvaluator` (env-allowlisted `python3` subprocess), `_ck_inputs.py` delivery (worker) + browser seed endpoint — see `docs/personalization-phase1.md`, `docs/inputs.md` |
| Per-student *expected answers* without revealing them | Pattern-family `expectedVarRef` → server-resolved into `_ck_inputs.py` — see `docs/personalization-pattern-families.md` |
| Reproducible, cache-safe materialization | Runner-side `TestSetupCache` (content-hashed prepared dirs); generated scripts stay byte-identical across students |
| Re-grade on content change | `retestAllSubmissionsForSetup` / manifest-hash gating (v0.4.93) |
| Agent authoring surface | MCP content tools (`author_script(tier:"support")`, `get_support_files`, families, notebook checks) |

---

## Phase 1 — Datasets (static, instructor-hosted)

### Goal

Promote "a CSV bundled in the test-setup zip" into a first-class artifact:
uploaded once, **versioned**, **reusable across assignments**, carrying
**provenance/licence metadata**, and **sliceable per student**.

### Why bother (vs. just using support files)

- **Reuse.** A course's VitalDB extract, a synthetic EHR, a SNOMED subset —
  attach the same dataset to many labs/assignments without re-uploading.
- **Versioning + reproducibility.** A dataset has a version and a content
  hash. Attachments **pin a version**, so bumping a dataset does not
  silently change how a closed assignment grades until the instructor
  re-pins and re-validates (mirrors the existing manifest-hash retest gate).
- **Size.** Stored once in a blob store, not duplicated into every zip.
- **Governance.** A central place for licence + provenance — load-bearing
  for health data (see "Privacy" below).
- **Per-student slicing as a first-class operation**, not ad-hoc code in
  each test script.

### Sketch

**Core model** (`Sources/Core/`, `Codable`/`Sendable`, no Vapor):

```swift
struct Dataset: Codable, Sendable {
    let id: UUID
    let courseID: UUID
    let name: String
    let slug: String              // per-course unique
    let version: Int              // monotonic; attachments pin a version
    let files: [DatasetFile]      // path, sizeBytes, sha256, mediaType
    let schema: DatasetSchema?    // optional column/table description
    let provenance: String?       // where it came from
    let licence: String?          // licence / usage terms
    let createdAt: Date
}
```

**Storage.** On-disk blob store, e.g. `datasets/{courseID}/{datasetID}/{version}/…`,
plus a `datasets` table. Instructor/admin-authored only; **never**
student-writable.

**Attachment.** An `assignment_datasets` join: `(assignmentID, datasetID,
versionPin, mountPath, sliceSpec?)`. `mountPath` defaults to `data/`. The
attachment is part of the assignment's manifest hash, so attaching/swapping
a dataset re-triggers validation and the retest fan-out like any other
content change.

**Materialization at grade time.** When the grading workspace is built, the
pinned dataset version is copied/symlinked in at `mountPath`:

- *Worker:* extend the `TestSetupCache` key to include dataset content
  hashes so a version bump busts the entry cleanly. The dataset rides the
  same prepared-dir cache as the test setup.
- *Browser:* `BrowserRunnerRoutes` already streams the test-setup zip into
  the Pyodide FS; add a parallel dataset fetch into `mountPath`. **Caveat:**
  large datasets over the browser path mean a large per-grade download —
  worker mode is the better home for big datasets (see "Open questions").

**Per-student slicing.** An attachment may carry a server-side slice
expression evaluated with the student's seed (reusing
`PersonalizationEvaluator`), producing either:

- a per-student `_ck_inputs.py` (e.g. `patient_ids = [...]`, `ward = "3B"`)
  that student/test code reads, or
- a per-student materialized *view* file written into the workspace.

Deterministic and server-side, exactly like today's personalization.

**MCP surface** (natural extension of existing content tools):
`create_dataset`, `list_datasets`, `get_dataset` (list files / read a head,
like `get_support_files`), `attach_dataset` / `detach_dataset`,
`set_dataset_slice`.

### Migration

Support-file CSVs are the v0 of this. Assignment 4 is the first consumer:
its `assignment4_vitaldb_cases.csv` becomes a Dataset, attached at
`data/`, and the existing notebook checks are unchanged.

---

## Phase 2 — Databases (a living, queryable layer on top of a dataset)

### Goal

Give students something they **query and investigate** that *feels* like a
real database / clinical system, layered on a Phase 1 dataset, running
in-process with no network, **per student**, and gradeable — so we can
build mystery / investigation assignments.

### The core idea: ship a query *shim*, not a server

A **Database** is a versioned artifact = one or more datasets + a
**pure-Python query module** (the "shim") + a **scenario spec**. The shim is
materialized into the workspace and the student imports it:

```python
from hospital import db          # the shim, backed by the local dataset

# feels like a database — but it is reading local files, no network
patient = db.read("Patient", id="P0412")
labs    = db.search("Observation", patient="P0412", code="WBC")
rows    = db.query("SELECT ward, COUNT(*) FROM admissions "
                   "WHERE positive = 1 GROUP BY ward")
```

Two API flavours, both pure-Python and available under **both** grading
paths:

1. **Relational / SQL** — back the shim with **`sqlite3`** (in the CPython
   stdlib *and* compiled into Pyodide) over an in-memory DB built from the
   dataset at import time. Students write real SQL — a genuinely valuable
   health-informatics skill — with zero network and zero server process.
   This is the cleanest "feels like a real database."
2. **FHIR-/record-shaped** — `db.read(resourceType, id)` /
   `db.search(resourceType, **params)` returning record objects from local
   bundles. Good for "navigate an EHR" framing; a thin wrapper over the same
   local store.

### The "living / simulation" layer (the step higher)

Static reads are not yet *alive*. The simulation layer makes the world
**respond** to the student:

- **State & time.** A `db.tick()` / simulated clock; lab results that
  "arrive" after they're ordered; vitals that drift; an outbreak that
  spreads a little with each simulated day. The student investigates by
  issuing queries; the world evolves in response.
- **Deterministic from the seed.** The *entire* simulation is a pure
  function of `(dataset, seed, the student's query sequence)`. This is
  non-negotiable for autograding: the grader can replay the same sequence
  and verify the student reached the right conclusion, and the **correct
  answer** for each student (patient zero, the contaminated ward, the
  interacting drug pair) is derivable server-side from the seed.
- **Per-student mysteries.** The seed selects scenario parameters, so every
  student investigates a different case. Copy-paste fails: a peer's answer
  is the answer to the *peer's* mystery.

### How a mystery assignment grades

1. The student uses the shim to investigate and writes their conclusion,
   e.g. `answer_ward = "3B"` or `patient_zero = "P0412"`.
2. A pattern family / notebook check verifies the conclusion. The expected
   value is per-student via **`expectedVarRef`** (already supported for
   `boundary_equality`): the server resolves the seed-derived correct answer
   into `_ck_inputs.py` so the visible test never contains the answer.
3. *(Optional, later)* grade **method**, not just the answer: the shim can
   log the student's query trace and checks can assert they used the
   expected query shapes (analogous to today's `cell_contains` checks).

### Where it runs

The shim is just a pure-Python module shipped with the Database artifact
(stdlib `sqlite3` only — present in both CPython and Pyodide). The scenario
seed arrives via `CHICKADEE_ASSIGNMENT_SEED` (worker) / the browser seed
endpoint, exactly like personalization today. Generated test scripts stay
byte-identical across students; only the seed-resolved scenario differs —
so `spec_hash` / `TestSetupCache` keys are stable (matches the v0.4.343–347
per-student pattern-family design).

### Authoring

The instructor authors, server-side (like personalization expressions /
`solution.py`):

- the schema/tables (from the attached dataset),
- the query surface they want students to use,
- the simulation rules, and
- a **scenario generator**: `seed → (scenario params, correct answer)`.

The platform handles distribution and answer-key resolution. MCP tools
(`create_database`, `set_scenario_generator`, …) and a browser authoring
panel follow the existing patterns.

---

## Trust boundary — mysteries need a *secret*, and the browser cannot keep one

This is the most important design point in Phase 2, and it diverges from
ordinary personalization.

Normal personalization inputs (a student's ciphertext, their sampled rows)
are *meant to be visible* to the student — that is fine. A **mystery's
solution is a secret**. And **anything in the Pyodide filesystem is
inspectable** by a determined student (open devtools, read `_ck_inputs.py`).
So a seed-derived correct answer must **never be shipped to the browser**.

Therefore, secret-answer mystery assignments must use one of:

- **Worker grading (recommended).** `_ck_inputs.py` carrying the answer
  lives only in the server-side worker workspace and never reaches the
  student. The student's submitted conclusion is checked there.
- **Server-side answer check.** The browser submits the student's
  conclusion; the server compares it against the seed-derived answer it
  computes itself, and never sends the answer down. (Note the v0.4.x audit
  already moved attempt-number / first-pass reconciliation server-side for
  browser results — same spirit.)

Set the default grading mode for these assignments to `worker` and document
why. A purely browser-graded mystery with the answer in the workspace is not
secure.

A second, smaller concern: the seed itself reaches the browser (it must, for
visible personalization). For mysteries, ensure the *answer* is not trivially
recomputable from the seed by client-side code — i.e. keep the scenario
generator / answer function server-side, not shipped in the shim.

---

## Determinism discipline

The simulation must produce identical results under worker CPython and
in-browser Pyodide (also CPython, compiled to WASM). The usual hazards
apply, the same ones personalization already manages:

- Seed all randomness explicitly (`random.Random(seed)` /
  `numpy.random.default_rng(seed)`); never rely on `hash()` (salted per
  process) — use `hashlib`.
- Iterate deterministically (sort before iterating where order matters).
- Avoid platform-dependent float formatting in expected-answer comparisons;
  prefer tolerant comparison (`approximate_equality`) for numeric answers.

---

## Privacy & governance

HLTH 230 is health data; this is load-bearing, not a footnote.

- **Synthetic or licensed only.** Datasets must be synthetic
  (e.g. Synthea-generated) or carry a licence that permits classroom use.
  Real PHI must never enter the system. The `provenance` / `licence`
  fields exist to make this explicit and auditable.
- **No external leakage.** This is automatic — the air-gapped grading model
  means student code cannot exfiltrate a dataset over the network even if it
  tried (the same FIPPA/PIPEDA reasoning behind vendoring Pyodide locally).
- **Instructor/admin authored, never student-writable.** Datasets and
  databases follow the same role gating as other course content.

---

## Open questions / decisions

1. **Browser vs worker for large datasets.** Worker is the better home for
   anything sizeable (no per-grade download). Do we cap browser-path dataset
   size, or steer dataset-backed assignments to worker mode by default?
2. **Dataset vs Database as one artifact or two.** Model a Database as a
   *kind* of Dataset (dataset + shim + scenario), or a separate artifact
   that *references* datasets? Leaning: separate artifact referencing
   datasets, so one dataset feeds several database "framings."
3. **Answer-checking vs method-checking.** Start with answer-checking
   (cheap, reuses `expectedVarRef`); add query-trace/method grading later.
4. **Authoring language for the scenario generator.** Python server-side
   (consistent with personalization) is the obvious first answer; revisit if
   `docs/personalization-eval-runtime.md`'s move toward runner/browser eval
   lands.
5. **How much "shim" is canonical vs per-assignment.** Ship a small canonical
   query/simulation library, or let each Database carry its own module? A
   canonical core + per-assignment scenario is probably the right split.

---

## Phasing summary

- **Phase 1 — Datasets.** First-class, versioned, reusable, per-student-
  sliceable static data. Assignment 4's VitalDB CSV is the first consumer.
  Mostly new storage + a thin attachment/materialization seam over existing
  support-file and personalization machinery.
- **Phase 2 — Databases.** A pure-Python query shim + deterministic,
  seeded simulation layered on a dataset, gradeable via `expectedVarRef`,
  **worker-graded for secret-answer mysteries.** Enables per-student
  investigation/mystery assignments — the genuinely unique experience.

External live servers (HAPI FHIR + Synthea, public FHIR sandboxes) remain
useful for *interactive exploration outside grading*, but are explicitly
**not** part of the graded path, by the network constraint above.

---

## Phase 1 implementation plan — A4 worked example

This section is the concrete build plan, grounded in Assignment 4 (`J9L7x8`,
HLTH 230), which today bundles one support file `assignment4_vitaldb_cases.csv`
and grades exploratory analysis with five *structural* notebook checks (`df`
is a `DataFrame`, expected columns present as a superset, ≥2 figures, a cell
uses `describe`, a cell uses `groupby`).

### The shape

A dataset is **a support file marked "personalize", plus a sample size.** The
instructor uploads the *full pool* as an ordinary support file and flips a
toggle; each student receives a deterministic N-row sample **under the same
filename**, so the notebook's `pd.read_csv("assignment4_vitaldb_cases.csv")`
is unchanged and the student only ever sees their slice.

### Student view

No UI change. The editor opens, `pd.read_csv(...)` works as before, but the
rows are a per-student sample keyed to `CHICKADEE_ASSIGNMENT_SEED`. Their
`describe()` / charts / `groupby` numbers differ from every peer's, and what
they explore in the editor is exactly what the worker grades.

### Instructor view

In the **Files** panel of both authoring pages
(`Resources/Views/_assignment-edit-body.leaf` and `assignment-new.leaf`, the
`supportFileRows` loop) each support-file row carries one inline control. What
shipped is flatter than the expanding "Personalize ▾" this note first sketched
— the row count is the only setting, so there was nothing worth hiding behind
a disclosure:

```
Support file   assignment4_vitaldb_cases.csv                          [Remove]
               [x] Per-student sample  [ 500 ] rows per student        Saved
```

Persisted via `PUT /instructor/:id/datasets` (published) or
`PUT /instructor/new/draft/datasets?draftID=…` (create page), mirroring
`PUT /global-variables`. The uploaded file becomes the server-side *source*;
students receive only their sample.

### Data model (Core)

`Sources/Core/Models/DatasetSpec.swift`:

```swift
public enum DatasetKind: String, Codable, Sendable, Equatable { case rowSample }

public struct DatasetSpec: Codable, Equatable, Sendable {
    public let file: String         // the support filename that is a per-student dataset
    public let kind: DatasetKind     // .rowSample for MVP
    public let sampleSize: Int?      // rows per student; nil = whole file
}
```

`TestProperties` gains `datasets: [DatasetSpec]` (decoded with
`decodeIfPresent ?? []` for back-compat). It is a **server-side authoring
concern** — the worker receives the *materialized per-student file*, never the
spec — so `runnerSanitized()` drops it via the memberwise default, exactly like
`patternFamilies` / `globalExpressions`.

### Materialization (server-side, deterministic, one implementation)

`Sources/Core/DatasetMaterializer.swift`: a pure, Foundation-light function

```swift
DatasetMaterializer.materialize(source: String, spec: DatasetSpec, seedHex: String) -> String
```

For `.rowSample` it derives a `UInt64` from the 64-hex seed (FNV-1a, **not**
`hashValue`/`Hasher` — those are process-salted), drives a hand-rolled
SplitMix64 PRNG, picks `sampleSize` distinct data-row indices, and re-emits
the header plus the chosen rows **in original order**. Pure integer math →
identical bytes on macOS and Linux. The server resolves the bytes **once** and
delivers them to all consumers; nobody re-samples.

### The three delivery paths

The source and the sample share a filename, so each path delivers the sample
and hides the source (treat dataset-source support files as server-side-only,
like `solution.py`):

1. **Editor** (`NotebookWorkingCopyStore.swift:446–477`): for a dataset
   filename, **skip** the read-only shared symlink and instead write the
   materialized sample as a real file at notebook open (next to the existing
   `applyNotebookSubstitutionsIfNeeded` resolution, `:200`). Re-materialize
   when seed/source/params change.
2. **Worker** (`RunnerDaemon+JobProcessing.swift:583–600`): right where
   `_ck_inputs.py` is written into the **per-job scratch** workspace, also
   write the per-student dataset files (overwriting the source copied from the
   cached prepared dir). Resolve + attach in `WorkerJobRoutes.buildJobPayload`
   alongside `personalizedInputs`.
3. **Browser** (`BrowserRunnerRoutes` seed endpoint + `browser-runner.js`):
   extend the seed response with a per-student `files` map; the browser writes
   them into the Pyodide FS and the test-setup download strips the source.
   **Not needed for A4** (worker-graded) — only when a personalized dataset is
   used on a browser-graded assignment.

### Runner cache is preserved

The `TestSetupCache` is keyed by test-setup **content** (`testSetupID` + the
manifest/zip `downloadVersion` hash) — **no student identity**. Per-student
bytes never enter the cached `prepared/` dir; they are layered into the
**per-job scratch copy**, exactly as `_ck_inputs.py` already is. So the cache
stays shared and byte-identical across students. The cache would only break if
per-student data were baked into the cache key or the prepared dir — which this
design explicitly avoids. Editing the sample size changes the manifest hash and
busts the cache **once, for everyone** (and triggers the v0.4.93 retest
fan-out), which is correct.

### Grading impact for A4: zero check changes

All five A4 checks are structural, not value-based; a row sample preserves
columns and dtypes, so they pass unchanged. Pick N large enough (e.g. 500 of
6,388) that every category still appears for `groupby`.

### Trust boundary

For A4 this is **variety, not secrecy** — the sample is meant to be seen, so
delivering it to the editor/browser is fine. The only thing hidden is the full
pool. Secrecy becomes load-bearing only for Phase 2 mystery answers.

### Expressions read the student's slice, not the pool

The two per-student systems — `=` expressions and datasets — were built
independently and, for one release, disagreed. `PersonalizationEvaluator` spawns
its subprocess with the cwd set to the shared support directory so an expression
can `open("cases.csv")`. That directory holds the instructor's **pool**, and is
the same directory `DatasetResolver` reads as its *source*. In
`WorkerJobRoutes.buildJobPayload` the two sat thirteen lines apart and neither
knew about the other.

The consequence was not a crash but a silent wrong answer. An expression
computing `df["systolic"].mean()` returned the **pool's** mean, which then
travelled the `expectedVarRef` path into `_ck_inputs.*` as that student's
expected value — while the student held a slice with a different mean. Every
student got the same expected value, and every student's own data disagreed with
it. Only *structural* checks survived, which is why A4's five checks being
structural read as a coincidence rather than as the ceiling it was.

`PersonalizationSubstitution.resolve` now resolves the student's slices and hands
them to the evaluator, which spawns against a private overlay: symlinks to every
support file, with each declared dataset replaced by that student's bytes. Three
properties are load-bearing:

- **The shared directory is never written to.** Materializing a student's slice
  there would hand the next student the previous one's data. The overlay is
  per-evaluation and lives under the evaluator's existing temp directory.
- **Same source, same seed, same bytes.** The overlay resolves through
  `DatasetResolver` — the call the worker and editor already use — so the
  expression and the student's delivered file agree by construction, not because
  two call sites were kept in step.
- **A slice that cannot be written is left absent, not symlinked to the pool.**
  The expression then fails loudly with "no such file" rather than quietly
  computing the instructor's answer and shipping it as the student's. This is the
  one place the usual "forgiving at delivery" rule inverts: forgiveness here
  means being confidently wrong about a grade.

This is what makes a *value-based* check authorable on a dataset assignment at
all, and it is the prerequisite for any transform that changes values rather
than selecting rows.

## Derivation — selection says which rows, a transform says what was done to them

Phase 1 and 1.5 are both **selection**: `rowSample` and `stratifiedSample` decide
which of the instructor's rows a student receives, and only ever copy bytes.
**Derivation** alters the values themselves, so the pool becomes a *template*
and each student gets a variation improvised on it.

The two are separate axes on `DatasetSpec`, deliberately:

```swift
public let kind: DatasetKind               // SELECTION — unchanged meaning
public let transforms: [DatasetTransform]  // DERIVATION — decodeIfPresent ?? []
```

"500 rows balanced by ward, then 2% of `bp_systolic` blanked" is two independent
decisions. A `DatasetKind` case per combination is how that enum reaches thirty
cases, so combinations are expressed as a list rather than enumerated. Every
manifest written before derivation existed decodes to `transforms: []` and
materializes to exactly the bytes it did before.

**Selection runs first, then transforms in array order.** Both halves are
load-bearing: transforming after selection means a rate applies to what the
student actually receives rather than to the pool, and the order is stored
because blanking then jittering is not jittering then blanking.

### The rules that keep a transform from breaking its own assignment

- **Never touch the schema.** No column added, removed, renamed or reordered.
  The assignment ships code written against column *names*, and a student whose
  `df["systolic"]` raises `KeyError` cannot fix that. Rows and within-column
  values only.
- **Columns are named explicitly** — there is no wildcard. An instructor who
  blanks the column a notebook check asserts on has broken their own assignment;
  making them name it is what lets the save-time check tell them so.
- **A transform that cannot apply leaves the data alone**, and is refused at
  save. Same pairing as the stratum column: forgiving at delivery, loud while an
  instructor can still fix it.

### Determinism, which is harder here than for selection

Selection was platform-independent almost for free because it only copies bytes.
Generating values is where that stops being free, so three rules are enforced by
`DatasetTransformApplication.swift`:

1. **No `Double` reaches a delivered byte.** `rate` is an authored number, so it
   is folded to an integer per-mille once, up front — `(rows * permille) / 1000`
   — and every per-cell decision after that is integer math.
2. **Each step draws from its own sub-seeded stream**, keyed on the student's
   seed plus the step's index, kind *and* column. A shared stream would mean
   appending a second transform re-rolls the first, silently changing data
   already delivered to a whole class. Two tests pin this: appending a step
   leaves the first step's column byte-identical, and adding a column to a step
   leaves the other column's rows unmoved.
3. **Nothing iterates a `Dictionary` or `Set`.** Columns are visited in the
   order the instructor listed them, rows in file order.

A fourth rule is about *how* a cell is blanked: the raw line is edited in place
rather than split and re-joined. A rebuild would re-quote every other field by
this codebase's rules rather than the source's, changing bytes in cells the
transform was never asked to touch.

### `missingValues`

The first derivation, and deliberately the simplest: it blanks a deterministic
subset of cells in the named columns. Pure string replacement — no type
inference and no formatting decisions — which is why it goes first. It teaches
the handling of absent data, which is a real skill in health datasets rather
than a synthetic difficulty.

Save-time refusals (`DatasetSpecValidation.transformIssue`), each paired with
something delivery absorbs silently:

| Refused at save | Absorbed at delivery |
|---|---|
| a step naming no columns | leaves the data alone |
| a column the file's header does not carry | that column is skipped |
| a missing rate, or one outside `0 < rate <= 1` | the step does nothing |
| a rate too small to reach one row of the sample | integer fold yields 0 cells |
| the same kind twice on one column | order-dependent in a way nobody authored |

That last row deserves its own note: `(sampleSize * permille) / 1000` is exactly
what delivery computes, so 1% of a 10-row sample is genuinely zero cells. The
check knows the sample size and can say so, which is the same move
`stratifiedSample` makes when a sample is smaller than the category count.

### The Files-panel control

A dataset row carries the derivation step beside its sample size and stratum
column:

```
[x] Per-student sample  [ 500 ] rows per student  balanced across [ ward ]
    blanking [ bp_systolic ] in [ 10 ] % of rows                    Saved
```

Two design rules carried over from the stratum column:

- **The field carries whether the step exists.** Naming columns creates the
  step; clearing them removes it. There is no separate checkbox or mode picker,
  because a second control asking the same question in different words is how
  the two come to disagree.
- **Percentages in, fractions stored.** An instructor says "10% of rows"; the
  spec holds `rate: 0.1`, which delivery folds to an integer count.

**The panel edits one shape, and knows it.** It has fields for no transforms or
a single `missingValues` step. The model is an ordered list with more kinds to
come, so a spec authored through MCP can hold something the panel cannot draw —
two steps, or a future kind. Rendering that into the one pair of fields would
show half the truth and then save over the other half on the next row-count
edit, which is the silent-downgrade shape this feature has now produced twice.
So `EditableSuiteRow.datasetTransformsEditable` asks first, and a spec the panel
cannot represent renders **disabled**, with a note that the steps are
agent-authored, and survives unrelated edits intact.

That answer lives in two places on purpose and they are tested separately: Swift
decides it for the server-rendered first paint, and `Public/support-files.js`
honours it for every repaint after a save — omitting the `transforms` key
entirely when its fields are disabled, so the merge carries the stored steps
through.

### What is NOT built yet

`formatNoise` — inconsistent representations of the same value (stray
whitespace, letter case, `2024-01-02` vs `02/01/2024`) — is the natural next
transform, and the most pedagogically honest of the set: real health data
arrives like this, and it is **answer-preserving**, so correct parsing yields
the same result the pool would. (It was once the only transform safe to author
without multi-variant validation, for that reason; that gate exists now — see
below — so the ordering constraint is gone.)

### `numericJitter` is decided against — do not propose it again

Perturbing numeric values per student was the third transform in the original
handoff. It is **dropped**, deliberately and permanently, on three independent
grounds. Recorded here in full so the option is not rediscovered as an open
question:

1. **It buys no pedagogy.** Its only real benefit is anti-copying, and
   `rowSample` already delivers that. Unlike `missingValues` and `formatNoise`,
   there is no data-handling skill a student practises because a weight was
   nudged.
2. **It is the only transform that distorts a distribution.** `missingValues`
   chooses rows uniformly at random, independent of the cell's value, so it is
   MCAR by construction — it thins the data without biasing it. `formatNoise`
   changes representation, not value, so it is distribution-preserving too.
   Jitter inflates variance by construction, so every student would compute
   statistics over a cohort whose spread is wrong by design.
3. **It costs the most to get right and damages provenance most.** It needs
   fixed-point arithmetic at the source's own precision to stay deterministic,
   and a jittered VitalDB extract is no longer VitalDB: a student reporting "the
   mean systolic in this cohort is 128" reports a number that exists nowhere
   outside their own file.

The pedagogy it was reached for is better served by the transforms that keep the
data honest, and the anti-copying it was reached for already exists.

### Multi-variant validation — closing the one-variant gap

A validation submission grades the reference solution against the enqueuing
instructor's own seed — one variant of a per-student assignment. That used to
be the whole story: `hasPersonalization` counts expressions and variables, not
`datasets`, so `materializeValidationGrading` returned early for a dataset-only
assignment and validation proved nothing about the material other students
receive. For selection that was tolerable — the solution sees real rows, just
fewer. For derivation it was not: a solution that assumes a column is never
empty validated green and then failed for the students whose seed blanked it.

Every validation enqueue on an assignment that **varies by student** now also
grades the solution against `validationVariantCount` (4) synthetic seeds. The
pieces, and the decisions inside them:

- **The gate is a new predicate, `TestProperties.variesPerStudent`** — a
  per-student `=` expression or a per-student dataset. Deliberately *not* a
  widening of `hasPersonalization`, whose answer also steers the worker
  download path's sidecar behaviour; and literal-only personalization does not
  count, because every seed receives identical material and N identical runs
  prove nothing the first one did not.
- **The seeds are `DatasetDiagnostics.preflightSeed(0..<4)`** — the same
  derived seeds the Files-panel estimates sample, so the variant a validation
  grades is material the diagnostics already described. Derived, never random,
  pinned by test.
- **A variant is an ordinary `kind == .validation` submission** whose
  `SubmissionMaterialization` is pinned to the variant seed
  (`materializeValidationGrading(variantSeedHex:)`). Nothing downstream is
  new: the `.grading` sidecar, `_ck_inputs.*`, and the dataset slices
  `buildJobPayload` resolves from the cached `seedHex` all behave exactly as
  they would for a student holding that seed. With a variant seed the
  materialization is cached even when there is nothing to substitute — the
  dataset-only case the primary path deliberately skips.
- **The batch is recorded in `validation_variants`** (one row per variant:
  index, seed, submission id, verdict), keyed by test setup because the draft
  flow enqueues validation before the assignment row exists. Each enqueue
  *replaces* the setup's batch — and clears it outright when the manifest
  stops varying, so a stale verdict cannot keep describing an assignment that
  is no longer per-student. Result ingestion writes each verdict onto its
  variant row; the assignment's own `validationStatus` still reflects only
  the primary run.
- **Surfaces.** The instructor assignments list shows the batch under the
  validation cell ("4 variants passed" / "1 of 4 variants failed", linking to
  the failing variant's per-test results — an ordinary submission page). MCP
  `get_validation_result` reports the batch with each variant's seed and, for
  failed variants, only its non-passing outcomes.
- **A failed variant does not (yet) block opening the assignment.** The open
  gate still reads `validationStatus == "passed"`, i.e. the primary run.
  Display-first is deliberate for the first release: hard-blocking on variant
  failures would retroactively freeze existing dataset assignments mid-course
  the next time they are edited. Revisit once a term's worth of variant
  verdicts shows the false-positive rate is what it should be (zero).

### Build slices

1. **Core** — `DatasetSpec`, `TestProperties.datasets` + `runnerSanitized`
   strip, `DatasetMaterializer`, unit tests. *(self-contained; this slice)*
2. **Server resolution + worker delivery** — a `resolvedDatasetFiles` helper
   beside `PersonalizationSubstitution.gradingInputs`, job-payload plumbing,
   the per-job file write, source-hiding from student-facing zips/symlinks.
3. **Editor delivery** — per-student file write + symlink suppression.
4. **UI** — the Files-panel inline control + `PUT /datasets` endpoint (the
   endpoint shipped with slice 2; the control, and the draft-scoped sibling
   endpoint the create page needed, landed later — see "Authoring surfaces"
   above).
5. **Browser delivery** — only when a personalized dataset is used on a
   browser-graded assignment.
6. **Phase 1.5** — stratified sampling (shipped; see below). The
   arbitrary-Python `slice` escape hatch that used to sit in this slice is
   **not** planned: it was framed here as the bridge to Phase 2, and Phase 2 is
   declined (#1434), so the escape hatch has nothing to bridge to. Stratified
   sampling is the ceiling of the current design, not a step past it.

### Stratified sampling (`DatasetKind.stratifiedSample`)

A plain `rowSample` can drop a rare category outright — which quietly turns a
`groupby` exercise into a different exercise for the student who lost it. A
stratified spec names a `stratumColumn` and apportions the sample across that
column's distinct values, so every category in the pool is in every student's
slice.

The apportionment is Hamilton's method with a floor of one row per stratum,
in **integer arithmetic** — the point of `DatasetMaterializer` is that the same
(source, spec, seed) yields the same bytes on every platform forever, and a
floating-point rounding difference would be an invisible way to lose that.
A stratum never yields more rows than it holds; leftovers sweep in file order
to whichever strata still have room.

Two halves of one rule, worth keeping together:

- **Delivery degrades.** A stratified spec whose column the file no longer has
  falls back to a plain row sample rather than failing — the student gets their
  N rows unstratified instead of the whole pool everyone else has. By then the
  only reader is a student being graded, and an error helps them not at all.
- **Authoring refuses.** `DatasetSpecValidation` runs at every door (both PUTs
  and `set_dataset`): a stratified spec needs a column, the column must be in
  the file's header, and `sampleSize` must be at least the number of distinct
  values — a smaller sample cannot hold every category whatever the
  apportionment does. The messages name the file's real columns and its category
  count, because the instructor cannot see the file from the form they are
  typing into. A `stratumColumn` on a plain `rowSample` is refused too, rather
  than stored and ignored.

`DatasetSpecValidationTests.everySilentDegradationHasALoudRefusal` pins the
pairing: every case delivery absorbs quietly is a case saving rejects.

In the Files panel the column is the control — an empty box means a plain
sample, a column name means a stratified one — so there is no separate kind
picker for the two to disagree about.

**Authoring surfaces:** two, and they agree by construction.

- The **Files-panel control** on both authoring pages: each support-file row
  carries a "Per-student sample" toggle and a row count, saved in place with no
  page reload. The create page writes through a draft-scoped
  `GET`/`PUT /instructor/new/draft/datasets`, the edit page through the
  published `GET`/`PUT /instructor/:id/datasets`; both pairs share one
  validation + manifest-write core (`DatasetEditHelpers.swift`), so a spec one
  page accepts is one the other accepts. The behaviour lives once, in
  `Public/support-files.js`, which both pages already load — the two templates
  carry the same markup and differ only in the endpoint their page file passes
  in.
- The **`set_dataset` MCP tool** (mark a bundled support file with a
  `sampleSize`, `remove:true` to clear).

Both report from the same lookup — `TestProperties.datasetSpecsByFile`, read by
`get_support_files` for its `isDataset` / `datasetSampleSize` fields and by the
two support-row builders for the panel's controls — so the agent surface and
the web UI cannot describe one file differently.

A PUT **replaces the whole array**; it is not a patch endpoint, so a caller
sends the complete desired state. Either PUT rejects a body naming one file
twice, and `set_dataset` drops any existing spec for the file before appending
its own — two specs for one file would disagree about how many rows a student
gets, and which one won would be a detail of whichever consumer folded the
array.

## Diagnostics — how different is each student's data?

Two estimates about a dataset spec, shown in the Files panel and recomputed on
every saved parameter edit. Both are **read-only with respect to delivery**:
they describe the delivered bytes and never alter one — in particular, no seed
is ever reject-sampled to satisfy a tolerance, because a slice that depends on
an acceptance criterion silently changes for every student when the threshold
moves.

**Overlap — can students copy?** Closed form, per selection kind, behind an
exhaustive switch over `DatasetKind` (now `CaseIterable` so the completeness
guard can iterate it):

- `rowSample`: two size-`k` samples of an `N`-row pool share `k²/N` rows in
  expectation; the reported *shared fraction* is `k/N` — the fraction of one
  student's rows a peer also holds. Deliberately not Jaccard, whose union
  denominator is a set neither student has and which shrinks as students
  diverge, understating copying risk.
- `stratifiedSample`: `Σₛ kₛ²/Nₛ`, with `kₛ` from the real `apportion` call —
  never the `k/N` shortcut, which Titu's lemma makes a strict underestimate
  whenever allocation is non-proportional, and the one-row-per-stratum floor
  is non-proportional by construction. The consequence worth knowing: **a rare
  category with 5 pool rows and 2 rows per student is 40% shared** — turning
  on stratification to protect a rare category makes that category the most
  copyable part of the assignment. It is invisible in the aggregate number, so
  the panel names the most copyable stratum explicitly.
- The worst pair in a class (the pair the instructor hears from) is an
  extreme-value estimate over the class's C(C−1)/2 pairs, clamped to
  `[mean, k]`; class size is a stated constant, not configuration.

**Divergence — are students doing the same exercise?** Measured, not derived:
every sampled slice comes from `DatasetMaterializer.materialize` — the exact
call delivery makes — over 20 **derived** preflight seeds
(`DatasetDiagnostics.preflightSeed`, pinned by test so the numbers cannot
flicker between page loads). Because it measures the shipped bytes, it covers
every transform automatically, including kinds that do not exist yet. Per
column: Wasserstein-1 in units of the pool's SD for numeric columns (an exact
quantile-function integral — a sort, not an optimal-transport solve), total
variation for categorical. A column's distribution is that of its *observed*
(non-empty) values: a `missingValues` hole is thinning, not a value, which is
exactly what MCAR blanking preserves — pinned by the MCAR test. Aggregation is
max-and-name-the-column, never a mean (an average over 20 columns hides one
catastrophically skewed column behind 19 fine ones), and the two measures stay
two headlines because SD-units and TV are not commensurable.

**The asymmetry is the architecture.** Overlap is a function of *selection*
alone — transforms alter values inside a student's rows and never change which
rows they hold — so it is closed-form per kind and a new selection kind must
answer a formula (the `allCases` completeness test fails until it does, and an
analytic-vs-Monte-Carlo test checks the formula is *right*, not merely
present). Divergence has no per-kind logic at all. The row-set theorem that
licenses this split is itself a test (`transformsNeverChangeTheRowSet`); a
future row-dropping transform fails it, at which point the decomposition — not
the test — needs revisiting.

**The surface** is the Files panel, not the validation report — a live
parameter estimate wants to live where the parameters are, moving as the
instructor edits the row count (multi-variant validation shares the preflight
seeds but answers a different question at a different time). Each dataset row
shows **two inline chips, one concise number each**: `similarity NN%` (the
fraction of one student's rows a peer is expected to also hold — a
student-to-student similarity score) and `drift 0.NN` (the worst column's
typical normalized distance from the pool). Everything else — the expected
shared-row count, the unluckiest pair, the most-shared category under
stratification, which column drifts and in which measure, the unlucky-variant
value — rides each chip's hover title. This replaced a first-release
disclosure full of prose sentences, on maintainer feedback: the numbers are
for glancing at while dragging a row count, and the method belongs behind a
mouse-over, not in the row. The display strings are built server-side in one
tested place (`DatasetEditHelpers.datasetEstimateSummary`), and the blocks
ride the same GET/PUT the controls already use
(`DatasetsResponse.diagnostics`, computed off the event loop), so a saved
edit repaints the numbers with no second request. The two estimates pull in
opposite directions — more rows per student is fairer but more copyable — so
the chips are deliberately informational: no thresholds, no warnings, and no
gating on either number (instructors may legitimately want to *maximize*
divergence). Files above a stated byte ceiling skip the divergence sampling
and the drift chip says so (`drift —`); overlap, a single pass, is always
reported.

The drift chip's single number is the max across columns of the *median*
normalized divergence, whatever that column's measure — a deliberate
softening of the two-headline rule above for the glanceable layer only: SD
units and TV still are not commensurable, so the chip never mixes them
arithmetically (no averaging), and the title always names the column, the
measure, and the other measure's worst column when both kinds exist.

`numericJitter` stays dead (see above), and these diagnostics do not assume
it.

## Train/test splits & grader-only files (option B)

The dataset feature also supports **train/test splits**, built from two
composable building blocks (decided for v1; the auto-split and per-student
complement variants are deferred):

- **A — per-student served sample** (slices 1–2, shipped): each student is
  served a deterministic random subset of the pool as their *training* data.
- **B — reserved grader-only file** (this work): a bundled file served to
  **no student** — present only in the native worker's grading workspace.

Combined, **A + B** gives both the classic *shared-train / secret-test* split
(a plain served file + a grader-only test file) and the stronger
*random-train + reserved-holdout* (a per-student sample + a grader-only test
file).

### "Holdout" means nobody sees it — and which kind matters

- **Reserved holdout (globally secret):** rows/files served to no student,
  only in the worker workspace. Collusion-proof — the whole class pooling its
  training data still can't reconstruct it. This is option B and the default
  meaning of "holdout".
- **Per-student complement (individually unseen only):** grading a student on
  the rows that weren't in *their* sample. Cheap and uses all the data, but a
  row in student A's "test" set was student B's *training* data, so two
  students colluding can reconstruct it. **Not** secret — deferred (option D),
  and named "complement" to keep it distinct from a true holdout.

### Grader-only delivery matrix

A grader-only file must reach the worker and nothing student-facing. The
codebase already enforces exactly this shape for `solution.ipynb` via a
`reservedNames` set; grader-only files union the manifest's
`graderOnlyFiles` into that same set at each classification point:

| Path | Handler | Student-facing? | Grader-only action |
|------|---------|-----------------|--------------------|
| Worker download | `WorkerArtifactRoutes.downloadTestSetup` (HMAC) | no (trusted) | **keep** — streams the full stored zip as-is |
| Browser-runner download | `BrowserRunnerRoutes.downloadTestSetup` | **yes** | **filter** — stream a copy with grader-only entries removed (guarded no-op when none) |
| Student support-file download | `TestSetupRoutes.downloadSupportFile` | **yes** | **block** — union into `reservedNames` (already gates by name) |
| Editor symlinks | `NotebookWorkingCopyStore.createSupportFileSymlinks` | **yes** | **skip** — union into `reservedNames` |
| shared/ extraction | `extractSupportFilesToSharedDirectory` | (symlink source) | **skip** — union into `reservedNames` |
| MCP support listing | `GetSupportFilesTool` | yes (instructor) | **hide** — union into `reservedNames` |
| Instructor zip download | `TestSetupRoutes.downloadTestSetup` | no (`isInstructor` gate) | keep |

The stored zip keeps the grader-only file (so the worker gets it via its
download); only the *student-facing* paths exclude it. The browser-runner path
is the one that needs an active filter (it streams the whole zip); everything
else is a name-set union.

### Data model

`TestProperties.graderOnlyFiles: [String]` (decoded with `decodeIfPresent`
default `[]`; **stripped by `runnerSanitized()`** — the worker receives the
file via the zip and needs no marker). A grader-only file is otherwise an
ordinary support file; this list just flags it as student-hidden.

### Trust boundary & worker-grading

A grader-only file is a secret, so an assignment that declares one must be
**worker-graded** — the browser path can't keep it from the student even with
the download filter (a determined student controls their browser). The editor
ships the grading-mode lock + the 🔒 cues described under the UI section.

### Build order (safety)

Implement in this order so a grader-only file can never be *authored* before
it is *enforced*:

1. **Foundation** — `graderOnlyFiles` on `TestProperties` + `runnerSanitized`
   strip + tests. Inert: no authoring surface, so nothing can create one yet.
2. **Enforcement** — union `graderOnlyFiles` into `reservedNames` at the four
   student-facing classification points + the browser-runner filtered
   download, with tests asserting the worker download *includes* and the
   student/browser paths *exclude* a grader-only file.
3. **Authoring (last)** — the editor control + MCP, plus the worker-grading
   lock. Only after enforcement is in place.

## See also

- `docs/personalization-phase1.md` — the per-student seed contract
- `docs/inputs.md` — Global / section inputs and `$name` references
- `docs/personalization-pattern-families.md` — `expectedVarRef` server
  resolution (the mechanism mystery grading leans on)
- `docs/personalization-eval-runtime.md` — where personalization expressions
  are evaluated, and the direction of travel
- `docs/architecture.md` — targets, grading pipeline, sandboxing
