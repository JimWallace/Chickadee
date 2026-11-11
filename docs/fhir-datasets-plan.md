# FHIR JSON in the course dataset library — plan

The plan to extend the course dataset library
([datasets-course-library.md](datasets-course-library.md)) beyond CSV to FHIR
JSON, and to give a course a simulated live clinical data source.

Status: **P1, P2 and the pages half of P3 built; the MCP half of P3 and P4
onward planned.** The recommendations are in
§1, and the maintainer's decisions of 2026-11-11 are in §11. P1 adds the
format to the spec, the structural check, the summary and the pretty-printer
in Core. P2 gives the library a format: a dataset is created as CSV or FHIR
NDJSON and keeps it, a FHIR version stores its summary, and the clone and the
bundle carry the format. The P3 pages offer the format on the Datasets tab,
edit the FHIR dictionary and the example, show both on the Data page, and
serve the student's file as `mine.ndjson`. The dictionary prose and the
example pick are stored on the summary, so the clone, a new version and the
bundle carry them. The first
release is **shared only**: every student gets the whole FHIR file. Sampling by
patient (§4) is designed here but built later (P5).

---

## 1. Summary of the recommendations

| Question | Recommendation |
|---|---|
| Format | **NDJSON**: one FHIR R4 resource per line, resource types mixed in one file. A Bundle may be uploaded and is converted to NDJSON at upload (P4); the stored version is always NDJSON. |
| Validation | **Structural only.** Each line is a JSON object with a `resourceType` and an `id`, and no `resourceType`/`id` pair repeats. No profile validation. The patient-membership checks run only when a spec samples by patient (P5). |
| First release | **Shared only.** A FHIR spec has no sample, no partition, no stratum and no transforms, so every student gets the whole file through the existing `shared` link. |
| Unit of sampling (later, P5) | **The patient.** A patient's slice is the Patient line and every line whose `subject` or `patient` names it, plus the shared context lines (Practitioner, Organization, Location and the like). `sampleSize` counts patients; a partition deals patients. No strata. |
| Refused for FHIR | A stratum and transforms, always. In the first release, a sample and a partition too. From P5, a sampled spec on a file with a resource in two patients, a dangling patient reference, or a non-context resource with no patient. |
| Format discriminator | `DatasetFormat` in Core (`csv`, `fhirNdjson`) on the library dataset and on `DatasetSpec`, decoded as `csv`, encoded only when it is not `csv`, so no stored manifest changes a byte. |
| MCP | No new tool in the first release. `create_dataset` gains `format`; the read tools report it; `update_dataset` gains notes keyed by resource type and code. |
| Simulated live source | **Stage 1: option (c)**, an in-kernel helper that pages through the attached file, with a simulated clock that gives option (b) without a server. **Stage 2 (after Winter 2027): option (a)**, a same-origin read-only endpoint for the editor only, behind the same helper API. Grading always reads the file. |
| HLTH 230 Assignment 3 | **Yes, it can be ready before mid-March 2027**, with a go/no-go on **2027-02-13** (§10). Shared delivery makes the path three PRs. The fallback needs no code. |

---

## 2. Where the library is today

Every part of the library assumes a CSV with a header row. The places that
read the bytes, and so the places that must branch on the format:

| Area | Code | CSV assumption |
|---|---|---|
| Upload rules | `CourseDatasetService.validatedFilename`, `checkedUpload` | a bare `.csv` name; `DatasetDictionary.profile(csv:)` must accept the header |
| Dictionary | `DatasetDictionary.profile`, `carried(from:onto:)`, `editIssue`; `DatasetColumn` | columns from the header, types from the first 1000 rows |
| Version row | `APICourseDatasetVersion` (`row_count`, `columns_json`) | a row count and a column list |
| Selection | `DatasetMaterializer.select`, `sampleRows`, `sampleStratifiedRows`, `partitionRows`, `allParts`, `headerOnly` | the unit is a line after the header |
| Save-time checks | `DatasetSpecValidation.issue`, `transformIssue`, `selectionIssue`, `partitionIssue` | a stratum or transform column must be in the header |
| Transforms | `DatasetTransformApplication` | cells of a CSV row |
| Diagnostics | `DatasetDiagnostics.overlap`, `DatasetDivergence` | row counts; column distributions |
| Parts on disk | `DatasetPartStore` | `header.csv`, `part-<k>.csv` |
| Student download | `StudentDataRoutes` (`/testsetups/:id/data/:filename/mine.csv`), `StudentDatasetDelivery` | a `.csv` route and type |
| Staff download | `GET /instructor/datasets/download` | `<slug>-v<n>.csv` |
| Pages | `InstructorDatasetPage`, `CourseDataPage`, `DatasetUploadPanel`, the Files panel (`SupportFileRow.swift`, `Public/support-files.js`), the upload page | a column table, row counts, sample fields |
| Promote | `SupportFileLibraryState`, `CourseDatasetService.promote` | only a CSV offers "Move to course library" |
| MCP | `create_dataset`, `add_dataset_version` (`sourceUrl` "a CSV"), `get_dataset` (header and first rows), `update_dataset` (column prose), `attach_dataset` and `set_dataset` (`stratumColumn`) | column words throughout |
| Bundle | `BundledDataset`, bundle `schemaVersion` 2 | a server that knows version 2 profiles every file as CSV |

What does **not** need to change, because the library keeps decision D2 (the
pinned bytes are copied into the setup zip):

- The worker, `TestSetupCache` and the runner. `TestProperties.runnerSanitized()`
  strips every `DatasetSpec`; the runner sees only the materialized file.
- The seeds (`DatasetSeedDerivation`, `CourseSeedStore`, `DatasetDeals`) and
  every delivery path that calls `DatasetResolver.resolve`. They pass bytes;
  the format matters only inside the materializer.
- The personalization overlay (`DatasetOverlayDirectory`). An expression reads
  the student's file by name, and a Python expression can parse NDJSON with
  `json`.
- Storage accounting. Versions are blobs counted by `size_bytes`; parts are
  counted with the setup by `DiskUsage`.
- `DatasetDeliveryMode`. It reads only the spec, so a FHIR spec classifies the
  same way: no sample and no transforms is `shared`, a partition is `perPart`,
  a sample is `perStudent`.
- The ranked-activity rule. `DatasetSpec.isShared` reads only the spec.

---

## 3. Format

### Decision F1. NDJSON, not a Bundle

A version is **one `.ndjson` file**: one FHIR resource per line, any mix of
resource types, in any order.

Why NDJSON:

1. **It matches the materializer.** The materializer selects whole lines and
   never re-serializes them. NDJSON keeps that: a student's file is a subset of
   the pool's lines, byte for byte, in the pool's order. A Bundle would make
   the slice a new JSON document, and Foundation's JSON writer does not keep
   key order or number formatting on both platforms, so the bytes would depend
   on the serializer. That breaks "the server resolves the bytes one time" in
   a way a test could miss.
2. **It is the population-export format.** FHIR Bulk Data (`$export`) writes
   NDJSON, and Synthea writes it with `exporter.fhir.bulk_data = true`. A
   course that teaches "a feed of records" teaches the format real feeds use.
3. **It reads in one line of Python**, and each line is the nested dictionary
   the course already teaches:
   `resources = [json.loads(line) for line in open("ed_feed.ndjson")]`.
4. **It streams.** The helper in §8 pages through it without parsing the whole
   file first.

Bulk Data writes one file per resource type. The library takes one file, so
the instructor concatenates them (`cat *.ndjson > feed.ndjson`). One file
keeps "a dataset is a file under a known name", which every delivery path,
the Files panel and the student download rely on. A multi-file dataset is a
non-goal (§12).

The alternative that lost is the Bundle (`collection`, `searchset` or
`transaction`). Synthea's default output is one Bundle per patient. Accepting
a Bundle at upload and storing the converted NDJSON is a small, separate
phase (P4, decided in §11). The conversion re-encodes each entry once, at
upload; from then on the stored lines are fixed. The stored version is always
NDJSON, so nothing downstream sees a Bundle.

The extension is `.ndjson`. The media type for downloads is
`application/fhir+ndjson`.

### Decision F2. FHIR R4, checked for structure only

Upload runs `FHIRNdjsonProfile.profile(_:)` in Core, which
`throws(FHIRDatasetIssue)`. It refuses, with one message per case and the line
number:

- bytes that are not UTF-8, a blank file, or a version over 16 MB
  (`CourseDatasetService.maxVersionBytes`, unchanged);
- a line that is not a JSON object, or that has no string `resourceType` or no
  string `id`;
- the same `resourceType`/`id` pair on two lines.

Three more checks belong to sampling and run only when a spec samples or
partitions by patient (P5), at save time against the file: a resource whose
`subject` or `patient` names a `Patient/<id>` the file does not hold, a
resource that names two different patients, and a resource of a type outside
the **context list** that names no patient (§4, rule P3). A shared file needs
none of them, so the first release does not refuse a file for them. The
summary (§5) still counts the dangling references, so the instructor sees
them.

Blank lines are skipped, and `\r\n` is read as `\n`, as for CSV
(`DatasetMaterializer.normalizedLines`).

**No profile validation.** Validating against FHIR profiles (US Core, or the
base R4 StructureDefinitions) needs the full specification package and a
validator; the reference validator is Java, and Swift has none. The Swift rule
against importing a language runtime, and the size of the package, rule it
out. A dataset is instructor-authored and synthetic (D8), so the risk a
profile check removes is a malformed teaching file, which the instructor sees
on the Data page summary. A version records `fhirVersion: "4.0.1"` so that a
later R5 dataset is a value, not a migration.

---

## 4. The unit of sampling

This section is built in P5, not in the first release, which delivers a FHIR
file whole (§11, decision 1). It is designed now so that the first release
does not close it off: the spec field, the format switch in the materializer
and the save-time refusals are where P5 adds to.

### The patient is the unit

For a CSV the unit is a row. For FHIR it is a **patient**: the Patient
resource and the resources that belong to it.

- **P1. Membership.** A resource belongs to a patient when its top-level
  `subject.reference` or `patient.reference` is `Patient/<id>`. These two
  elements cover the resources a course uses: Observation, Encounter,
  Condition, Procedure, MedicationRequest, DiagnosticReport (`subject`);
  AllergyIntolerance, Immunization, Claim (`patient`). The FHIR Patient
  compartment definition lists more search parameters per type; the plan uses
  only these two elements, which keeps the rule one sentence long. A resource
  that reaches its patient only through another resource (an Observation with
  an `encounter` and no `subject`) is refused at upload, with a message that
  says to add the `subject`.
- **P2. Order.** Patients are numbered in the order their Patient lines appear
  in the file. Selection picks patient numbers; the student's file is every
  line of the picked patients plus the context lines, **in the pool's line
  order**. Nothing is re-sorted and no line is re-encoded.
- **P3. Context.** A resource of a type in the context list (Practitioner,
  PractitionerRole, Organization, Location, Medication, Device, Substance) and
  with no patient reference is shared context: it is in every student's file
  and in every part. Any other type with no patient is refused at upload,
  because "shared context" for an unknown type could hand every student
  another patient's data. The list is a `Set` in Core, extended by a code
  change with a test, not by configuration.

### How each selection field maps

| Field | CSV meaning | FHIR meaning |
|---|---|---|
| `sampleSize` | data rows | **patients** |
| `rowSample` | partial Fisher-Yates over row indices | the same algorithm over patient numbers, so D6 holds: a smaller course-scoped sample is a prefix of a larger one, in patients |
| `stratumColumn` | a header column | **refused** (§11, decision 3) |
| `partition`, `partCount` | row `i` in part `i mod N` | patient `i` in part `i mod N`; context lines in every part |
| `scope` `course`/`assignment` | which seed picks the rows | unchanged |
| `transforms` | `missingValues`, `formatNoise` | **refused** |

**Strata are not built.** A FHIR spec with a `stratumColumn` is refused at
save. If they are wanted later, the natural form is a top-level string element
of Patient, such as `gender`.

**Transforms are refused.** `missingValues` blanks a cell. On a FHIR resource
the equivalent removes an element or a `value[x]`, which changes the JSON and
needs a serializer whose bytes are stable on both platforms. It also has to
keep each resource valid (an Observation with no value needs a
`dataAbsentReason`). Both are worth doing later, as a FHIR-specific transform
kind with its own design, not as a reuse of the CSV kinds.

**What a header row was, and what replaces it.** Two places use the CSV
header alone: a partition student who holds no part yet
(`DatasetDeals.withholdingUndealtParts`) and `DatasetPartStore`'s
`header.csv`. For FHIR the equivalent is the **context lines only**: no
patient, but the Practitioners and Locations, so a student's code can run on
an empty feed. `DatasetMaterializer.headerOnly` becomes a format switch.

### Diagnostics

- `DatasetDiagnostics.overlap` is a formula over the unit count and the
  sample size. It answers for FHIR with patients in place of rows.
- `DatasetDivergence` compares column distributions. FHIR has no columns. The
  first release reports "not measured for a FHIR dataset" in the chip and in
  `get_validation_result`. A later version could measure the distribution of
  each code's numeric `valueQuantity`; it is not needed for grading.
- Multi-variant validation needs nothing: each variant is a seed through the
  materializer.

---

## 5. Data dictionary and the Data page

### What a FHIR version records

Upload computes a **summary** (`FHIRDatasetSummary`, Core, `Codable`):

- the patient count (stored in `row_count`, which the pages label by format:
  "300 patients" or "3,000 rows");
- per resource type, its line count;
- the **codes in use**: for each resource with a top-level `code` (a
  CodeableConcept), each `coding` as (resource type, system, code, display)
  with a count. Systems are named for students: `http://loinc.org` is LOINC,
  `http://snomed.info/sct` is SNOMED CT, `http://hl7.org/fhir/sid/icd-10` and
  `-cm` are ICD-10 and ICD-10-CM; any other system shows its URI. The list
  stops at 500 distinct codes, and the summary says how many it left out;
- for each Observation code, the units seen in `valueQuantity.unit`, so the
  dictionary can show "8310-5 Body temperature, Cel" without prose.

### What the instructor writes

The CSV dictionary is prose per column. The FHIR dictionary is prose per
**entry**, where an entry is a resource type or a (resource type, system,
code) triple: "Observation 59408-5: oxygen saturation by pulse oximetry, taken
at triage". `carried(from:onto:)` and `editIssue` get FHIR counterparts that
key on the entry instead of the column name: prose carries to a new version
when the entry is still present, and an entry the file does not have is
refused at save (D7, unchanged in spirit).

The instructor also picks the **example resource**: a type and an id from the
newest version. The default is the first Observation.

### The Data page

For a FHIR dataset, `CourseDataPage` shows, in place of the column table:

1. the counts: patients, and lines per resource type;
2. the codes in use, grouped by system, each with its display, unit, count and
   the instructor's prose;
3. the example resource, pretty-printed in a `<pre>` block.

**Pretty-printing keeps key order.** FHIR writes `resourceType` first, and a
reader expects it there. `JSONSerialization` neither keeps key order nor
writes the same bytes on macOS and Linux. The page uses a small re-indenter in
Core that walks the original line's tokens and adds whitespace only. A test
pins its output on a fixture, on both platforms in CI.

The example comes from the pool. D9 says a student never downloads the pool;
one synthetic resource chosen by the instructor is not a download, and the
maintainer accepted it (§11, decision 2).

"Your rows" stays one download per assignment, served as `mine.ndjson` for a
FHIR file (§7).

---

## 6. Model and migration

### Core

- **`DatasetFormat`** (`Sources/Core/Models/DatasetFormat.swift`):
  `enum DatasetFormat: String, Codable, Sendable, CaseIterable { case csv, fhirNdjson }`.
  Every reader switches on it exhaustively, so a third format does not compile
  until each reader answers.
- **`DatasetSpec.format`**, decoded as `.csv` when absent. `DatasetSpec`'s own
  encoder writes it only when it is not `.csv`, as it does for `source`,
  `scope` and `partCount`, so a stored manifest keeps its bytes and its hash
  (the retest fan-out and the runner cache read the hash). The existing byte
  pin in `DatasetLibraryFieldsTests` gains a FHIR case.
- **Every rebuild of a `DatasetSpec` carries `format`**, as it carries the
  library fields and `partCount` (`docs/feature-interactions.md`). After a
  detach the file keeps its spec, so the format must live on the spec, not
  only on the library dataset.
- **The format and the extension must agree** at save: a `fhirNdjson` spec on
  a file that is not `.ndjson`, or the reverse, is refused while authoring.
  Grading and delivery never refuse: a mismatch that reaches the materializer
  through a whole-manifest door (a bundle import, a restore) is materialized
  by the spec's format, and a file that does not parse is delivered as the
  CSV path delivers a broken file today, which is unchanged bytes.
- **`FHIRNdjsonProfile`**, **`FHIRDatasetSummary`**, **`FHIRDatasetIssue`**
  (`throws(FHIRDatasetIssue)`), the patient index used by the materializer, and
  the re-indenter. All in `Core`, not `RunnerCore`: nothing on the grading side
  reads FHIR, and `RunnerCore` must stay Embedded-Swift-compatible.
- JSON is read with Foundation into a small `JSONValue` enum, only to index
  the file and build the summary. **No line is ever re-encoded.**

### Server

One migration, `AddCourseDatasetFormat`:

- `course_datasets.format`: text, not null, default `'csv'`. Set at create and
  never changed; `add_dataset_version` refuses a file of another format.
- `course_dataset_versions.summary_json`: nullable text, the FHIR summary and
  the entry prose. Null for a CSV version, whose dictionary stays in
  `columns_json`. A FHIR version stores `[]` in `columns_json`.

No new table, no new environment variable, no change to the MCP least-privilege
grants (they are per table, and the tables are the same).

**The bundle.** A bundle that carries a FHIR dataset is `schemaVersion` 3,
with `format` on `BundledDataset`. A course with only CSV datasets still
exports version 2, so an older server reads it. Version 3 exists because a
version 2 server would profile an NDJSON file as a CSV, and a JSON line can
pass as a one-column header: the import would succeed with a wrong dataset.
An older server refuses an unknown version, which is the right failure. The
clone copies the format with the row.

---

## 7. The MCP surface

No tool is added in the first release, so `MCPToolCatalog.live` keeps its
count. The changes are to schemas, descriptions and results:

| Tool | Change |
|---|---|
| `create_dataset` | gains `format` (`csv` or `fhirNdjson`), optional, default `csv`, so every existing call is unchanged. `sourceUrl` is the same SSRF-guarded fetch; the file rules follow the format. A promote takes a `.ndjson` support file. A `sourceUrl` or filename whose extension disagrees with `format` is refused with a message that names `format`. |
| `add_dataset_version` | the description stops saying "CSV"; the file must match the dataset's format. |
| `list_datasets`, `get_dataset` | report `format`. For FHIR, `get_dataset` returns the summary and the first 5 lines of the version in place of the header and first rows. |
| `update_dataset` | gains `entries` (resource type, optional system and code, description), changed by name as `columns` is today, so an agent that edits one entry does not clear the others. `columns` on a FHIR dataset is refused, and the reverse. |
| `attach_dataset` | the description says that a FHIR dataset attaches whole: a sample, a partition, a stratum and transforms are refused. From P5, it says that `sampleSize` and `partCount` count patients. |
| `set_dataset` | carries `format` through every edit; refuses a stratum and transforms on a FHIR spec, and a sample or a partition until P5; refuses to make a new spec on an `.ndjson` support file that is not attached (FHIR enters through the library). |
| `get_support_files`, `get_assignment` | report `datasetFormat`. |
| `initialize` instructions | the "Course dataset library" paragraph gains two sentences on FHIR. |

**How a FHIR file gets in.** Three doors, in order of use:

1. The Datasets tab upload form, with a format choice. This is the main door:
   an instructor generates the feed locally (as with the `dbgen.py` generator
   in Assignment 3's setup zip today, and
   running a generator server-side stays a non-goal) and uploads it.
2. `create_dataset` with `sourceUrl` and `format: "fhirNdjson"`, for a file an
   agent can reach over HTTPS.
3. Promote: author the `.ndjson` as a support file (`author_script`
   `tier:"support"`, within its size limit) and promote it.

**What pins the MCP surface in tests**, each of which this work touches:

- `MCPToolCatalog.live` (`Transport/MCPServerRegistration.swift`) is the count;
  no test pins the number itself.
- `MCPInstructionsCatalogSyncTests`: every tool is named in the instructions.
- `MCPOutputSchemaSyncTests`: every result matches its declared output schema.
  `get_dataset`'s schema gains the summary as an optional object.
- `MCPRoadmapDocSyncTests` and `docs/compliance/tool-inventory.md`: the rows of
  the dataset tools.
- `MCPEnrollmentDenialContractTests`, `MCPLeastPrivilegeGrantSyncTests`,
  `MCPKindProseCoverageTests` and `MCPActivityCoverageTests` iterate the
  catalog; they need a change only when a tool is added (stage 2 of §8).
- `CourseDatasetToolsTests` for the behaviour.

---

## 8. A simulated live source

### The constraint

Grading is offline and deterministic. On the native worker a test runs under
`unshare --user --net` (Linux) or `sandbox-exec` with no remote network
(macOS), so student code cannot open a socket. Browser grading runs in the
student's kernel, which can reach the server, but a grade that depends on a
server's answer at the moment of grading is not reproducible. **Whatever the
student explores, the graded code must read the attached file.**

Two facts from the editor decide what is possible in the browser:

- The CSP is `connect-src 'self'` (`SecurityHeadersMiddleware`). Same-origin
  requests are allowed; nothing else is.
- The Python kernel can make a same-origin HTTP request. `xeus-python` loads
  `pyodide-http`, which routes `urllib` through a synchronous XHR in the
  kernel's worker; the kernel mounts the JupyterLite Drive this way, and
  `scripts/patch-xeus-python-http.py` keeps that path working on both engines.
  `requests` is not in the environment (`environment-python.yml`), so the
  student would use `urllib.request`. The R, Lua and Octave kernels have no
  HTTP client in their environments.

### Option (a): a read-only FHIR-like endpoint per assignment

`GET /fhir/:setupID/<Type>?patient=&code=&_count=&_since=`, answering a FHIR
`searchset` Bundle with `link.next` paging, built from **the caller's own
slice** (`StudentDatasetDelivery`, so the bytes agree with "my rows" and with
grading).

- **Isolation.** The request is same-origin from the kernel worker, so COEP
  `require-corp` does not block it and `connect-src 'self'` admits it. No new
  Web Worker script is spawned, so `NotebookAssetIsolationMiddleware.isolatedWorkerScripts`
  does not change. Safari runs the editor non-isolated, which changes nothing
  for a same-origin XHR. The response needs `Cache-Control: private, no-store`,
  like the download.
- **Access.** The session cookie, an enrollment, and the closed-assignment
  gate, as for the download. A rate limit (the pattern of
  `ContentsWriteRateLimitMiddleware`), since a student loop can poll.
- **Grading.** It does not participate. The native worker has no network. A
  browser-graded lab would reach the endpoint, so the endpoint answers a
  grading worker's request with 403, and the helper's file transport is what
  graded code uses.
- **Cost.** A new route family, an authorization matrix row, a rate limiter, a
  feature-interactions section, and a new MCP tool or field to turn it on.
  Python only.

### Option (b): a time-released feed

Messages appear as simulated time passes. Two clocks are possible:

- **Wall-clock release** (a message is visible after its time, measured from
  when the assignment opens) needs a server, so it is option (a) with a
  filter, and a grade would depend on when the student submitted. Grading
  would have to pin the clock (for example to the end of the feed), and then
  the student's exploration and their grade see different data.
- **A simulated clock owned by the student's code**: `feed.advance(minutes=15)`
  returns the resources whose time falls in the next 15 simulated minutes. The
  result is a pure function of the file and the cursor, so it is deterministic,
  works offline, and is the same in the editor and in both graders.

The simulated clock is the one to build. It is not a server feature; it is a
method of the helper in option (c).

### Option (c): an in-kernel helper over the attached file

A Python module, `chickadee_fhir.py`, that the instructor ships as a support
file (the repository rule: the instructor bundles the helper library; the
runner injects nothing). It reads the attached NDJSON and offers an API shaped
like a FHIR server:

```python
from chickadee_fhir import Feed

feed = Feed("ed_feed.ndjson")
page = feed.search("Observation", code="8310-5", _count=50)
while page:
    for obs in page.resources:
        ...
    page = page.next()

feed.clock.start_at("2027-03-01T08:00:00Z")
arrivals = feed.advance(minutes=15)
```

- **Isolation.** Nothing new. It reads a local file in the kernel.
- **Grading.** Deterministic and offline under the worker and the browser
  grader alike, because it is a pure function of the file, the arguments and
  the cursor. The time field per resource type is fixed in the helper
  (`effectiveDateTime`, `period.start`, `issued`), and resources with none
  arrive at the start.
- **Cost.** No Swift. A tested module and a worked assignment.

### Recommended staged path

1. **Stage 1, for Winter 2027:** option (c) with the simulated clock, which is
   option (b) without a server. The helper lives in Assignment 3's support
   files. A reference copy with its tests can go under `docs/examples/` once it
   has been used once.
2. **Stage 2, after the term (P6, decided in §11):** option (a), for the
   editor only, behind the **same** helper API: `Feed.connect()` uses HTTP when
   the endpoint answers and the file otherwise, and graded code is told to
   take the resources as an argument rather than fetch them. The pedagogical
   gain is real HTTP (status codes, paging by URL); the cost is §8(a). Decide
   it on what Stage 1 shows students needed.

---

## 9. Feature interactions and risks

A new section of `docs/feature-interactions.md`, **"Dataset format:
`DatasetFormat`"**, lands with P1: the readers that branch on the format
(every row of §2's table), and the rules "a line is never re-encoded",
"every rebuild carries `format`", and "the format and the extension agree at
save".

| Interaction | What happens | Rule or risk |
|---|---|---|
| Versioning and pinning | A new version is pinned per attachment, as today. D6 holds in patients: an edit that keeps the patient count keeps every student's patients; an edit that adds or removes a patient deals every cohort again. | The Datasets tab's "which kind of change" note counts patients for FHIR. A new version that adds Observations to existing patients keeps the cohort. |
| Format change across versions | Refused: a dataset's format is fixed at create. | A course that moves from CSV to FHIR makes a new dataset. |
| Storage | 16 MB per version, unchanged. FHIR is verbose: an Observation line is 500 to 900 bytes. 300 patients with 12 sets of three vitals is about 10,800 Observations, 6 to 10 MB. | The first release is shared, so each student's copy is a link (`dataset-shared-delivery.md`) and the file is stored once. From P5, a sampled FHIR dataset is `perStudent`: a 60-patient sample is about 2 MB per student, 600 MB for 300 students. The P5 authoring note says so. |
| Class activities | `isShared` reads the spec only, so a whole FHIR file is allowed in a ranked activity and a sampled one is refused, exactly as for CSV. | None new. The simulated clock is deterministic, so it does not make a shared file personal. |
| Jobs with no student | The class corpus run and a composite reference render read the pool. | Unchanged. |
| Personalization expressions | Read the student's NDJSON by name in the overlay. | A Python expression must `json.loads` each line; the authoring docs give the pattern. |
| Course cohort | Unchanged; the cohort seed picks patient numbers. | — |
| Browser grading download | The materialized file is sent per grade. | Assignment 3 is an Assignment, graded by the worker, so it does not pay this. A browser-graded lab with a large FHIR file would. |
| JupyterLite | The file browser opens an unknown extension in the text editor; a 10 MB single-line-per-resource file is slow to open there. | Student code reads it with `open`; the Data page is where students look at the data. Checked in P3 on the real editor. |
| Bundle import into an older server | A version 2 server would profile NDJSON as a CSV. | Bundle `schemaVersion` 3 (§6). |
| R students | The helper and the endpoint are Python. | No R helper for now (§11, decision 6). |

The main risk is the **patient-membership rule**. A resource that reaches its
patient by another path, or a type missing from the context list, either is
refused at upload (safe, and the instructor fixes the file) or, if the rule
were looser, would hand every student another patient's records. The plan
takes the strict side and pins it with fixtures for each refused case.

---

## 10. Phased delivery

Each phase is one PR with its own `changelog.d/` fragment, `diff-reviewer`
before the commit, `interaction-review` on every phase that touches `Sources/`,
and `ui-review` on every phase that touches a view or `Public/*.js`. Swift
Testing only; every new suite that spawns a subprocess has a time limit. Test
files that already exist are edited only with the maintainer's approval (the
`ask-before-test-edit` hook).

| Phase | What | Tests | Size |
|---|---|---|---|
P1 to P3 are the Assignment 3 path. P4 to P6 follow it, in any order.

| Phase | What | Tests | Size |
|---|---|---|---|
| P1 Core, shared | `DatasetFormat`; `DatasetSpec.format` with the stable encoder; `FHIRNdjsonProfile` (the structural checks of F2), `FHIRDatasetSummary`, `FHIRDatasetIssue`; the format switch in `DatasetMaterializer` (a FHIR spec delivers the whole file); `DatasetSpecValidation` refusals (a sample, a partition, a stratum and transforms on a FHIR spec; format and extension agree); the re-indenter; the feature-interactions section | `FHIRNdjsonProfileTests` (each refusal, by fixture); a FHIR spec materializes to the source bytes for any seed; the encoder byte pin; `DatasetDeliveryModeTests` (a FHIR spec is `shared`) | one PR |
| P2 Library | the migration; `CourseDatasetService` create, add version, promote by format; the summary on the version row; staff download by extension; bundle `schemaVersion` 3; clone | `CourseDatasetServiceTests` FHIR cases; `CourseDatasetBundleTests` v3 round trip and v2 export when no FHIR dataset; `CourseDatasetLifecycleTests` clone | one PR |
| P3 Surfaces and MCP | Datasets tab: format choice on upload, the FHIR dictionary (entries), the example pick; `CourseDataPage` summary and example; `mine.ndjson`; Files panel: a FHIR row shows no sample, partition or transform controls; upload page wording; the MCP changes of §7 | `ElementaryPageGuardTests`, the dataset page fixtures, `StudentDataRoutesTests` (byte equality with the grader for FHIR), `RouteAuthorizationMatrixTests`, `support-files-library.test.mjs`; `CourseDatasetToolsTests`, `MCPOutputSchemaSyncTests`, `MCPInstructionsCatalogSyncTests`, the roadmap and compliance rows; a check on the real editor that the file opens | two PRs: pages, then MCP |
| Helper (content) | `chickadee_fhir.py` (§8(c) with the simulated clock) and Assignment 3's feed, as course content | the helper's own tests run in the assignment's validation; a worker-graded validation run green | content, not a platform PR |
| P4 Bundle upload | convert a Bundle to NDJSON at upload, writing each entry's `resource` as one line in entry order; the version note says it was converted | conversion fixtures, including a Bundle whose entries use `urn:uuid` references, which are rewritten to `<Type>/<id>` | one PR |
| P5 Sampling by patient | §4: the patient index; `rowSample` and `partition` by patient; `allParts` and the context-only "header"; `DatasetPartStore` names by extension; the membership refusals at save; `overlap` in patients; the Files panel and MCP sample fields for FHIR | `FHIRDatasetMaterializerTests` (lines verbatim and in pool order, nested-sample prefix in patients, parts disjoint and covering, context in every part); each membership refusal by fixture; `DatasetPartStoreTests` FHIR case | one or two PRs, when customization is revisited |
| P6 Live endpoint | §8(a), for the editor, behind the helper's API | route, authorization, rate-limit and isolation tests; a new MCP tool or field and every catalog test in §7 | two PRs, not required now |

### HLTH 230 Assignment 3

Assignment 3 (`eQCS0i`) is due 2027-03-20. Assignment 2 is due 2027-02-27, so
Assignment 3 most likely opens around then. Its final question is a
vital-signs screen (body temperature LOINC 8310-5, heart rate 8867-4, oxygen
saturation 59408-5) over a simulated emergency-department feed of about 300
patients.

**Can a FHIR dataset be ready before mid-March 2027? Yes, with a gate.**
Every student gets the same 300 patients (§11, decision 1), so the path is P1
to P3 deployed and the helper authored: four platform PRs, none of which
touches selection, on code whose shape the CSV library already set, with
roughly thirteen weeks before the gate. The MCP half of P3 is wanted for agent
authoring but is not required, because the upload form is a door. The
patient-membership rule, the part of this plan that most needs care, is in P5
and off this path.

**Go/no-go on 2027-02-13**, two weeks before the likely open: P1 to P3 are
live in production, the Assignment 3 feed is uploaded and published, and a
validation run is green on the worker. If any is missing, use the fallback.

**The fallback needs no platform code.** A CSV with one row per HL7 v2
segment (`message_id`, `patient_id`, `segment_index`, `segment`), parsed into
messages by a helper in the support files. It must be delivered **whole**
(`shared`, no sample): a `rowSample` or a `partition` picks rows, so it would
split a message across students. Per-student variation, if wanted, then comes
from the helper choosing patients by the seed, which is the kind of ad hoc
sampling the library exists to replace, so the fallback should stay shared.

---

## 11. Decisions by the maintainer

The maintainer answered the open questions on 2026-11-11.

1. **Shared first. Decided.** The first release delivers a FHIR dataset whole
   to every student (`shared`). Per-student samples and partitions by patient
   are a later phase (P5), taken up when customization is revisited. Assignment
   3 gives every student the same 300 patients.
2. **The Data page example comes from the pool. Decided: yes.** One
   instructor-chosen synthetic resource is shown to every student. This is
   consistent with D9: it is not a download, and under decision 1 every
   student holds the whole file anyway.
3. **Strata. Decided: no.** No FHIR stratum in any phase of this plan. A FHIR
   spec with a `stratumColumn` is refused.
4. **Bundle upload. Decided: yes.** A Bundle may be uploaded and is stored as
   NDJSON (P4). It is not on the Assignment 3 path.
5. **The live endpoint. Decided: yes, later.** Build §8(a) (P6), but it is not
   required now and is not on the Assignment 3 path.
6. **R. Decided: not now.** No R helper.
7. **Assignment 3's open date. Confirmed:** about 2027-02-27, so the gate in
   §10 stands at 2027-02-13.

---

## 12. Non-goals

- HL7 v2 pipe text as a dataset format (the fallback above carries it as CSV).
- FHIR profile validation (F2).
- A multi-file dataset, such as one Bulk Data file per resource type.
- A FHIR server, a query layer or a database (#1434's decision stands; the
  endpoint in §8(a) is a read-only view of a file the student already has).
- Re-serializing JSON anywhere in the delivery path.
- FHIR transforms in the first release (§4).
- A wall-clock feed in the graded path (§8(b)).
- Running a generator server-side to make a version.
