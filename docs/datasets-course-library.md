# Datasets throughout a course: a course dataset library

The plan that takes the shipped per-assignment dataset feature
([datasets.md](datasets.md)) and makes it a course-level feature: one library
of datasets per course, attached to many assignments, with a per-student cohort
that stays the same from the first lab to the final assignment, and a page
where students can read about the data they work with.

Status: **proposed**. Nothing in this document is built. Each slice below
states what it adds and what proves it.

| slice | what | state |
|---|---|---|
| 0 | This design note | proposed |
| 1 | Core: `DatasetSource` and `DatasetSliceScope` on `DatasetSpec`; `DatasetSeedDerivation`; the data dictionary model | proposed |
| 2 | Server: the `course_datasets` and `course_dataset_versions` tables, the blob-backed store, `CourseDatasetService` | proposed |
| 3 | Attachment: copy a pinned version into the setup zip and record the source; promote a support file into the library; detect a newer version | proposed |
| 4 | Course cohort: the per-(student, course) seed, and `DatasetResolver` choosing the seed per spec at every delivery path | proposed |
| 5 | Instructor surfaces: the Datasets tab, the Files-panel picker and the scope control | proposed |
| 6 | Student surfaces: the course Data page, the assignment-page dataset line, the "my rows" download | proposed |
| 7 | MCP: `list_datasets`, `get_dataset`, `create_dataset`, `update_dataset`, `add_dataset_version`, `attach_dataset`, `detach_dataset`; `set_dataset` gains `scope` | proposed |
| 8 | Lifecycle: course clone, bundle export and import, storage page, purge | proposed |
| 9 | Migration of HLTH 230: promote the two live datasets; docs and CLAUDE.md | proposed |
| 10 | Optional: the `formatNoise` transform | proposed |

---

## 1. Where the feature is today

What shipped is narrower than the first design in `datasets.md` proposed. The
first design named a course-level, versioned, reusable artifact. What shipped
is **a support file in one assignment's zip, with a per-student sample**.

- `DatasetSpec` (`Sources/Core/Models/DatasetSpec.swift`) marks one support
  file in one assignment. It holds the selection (`rowSample` or
  `stratifiedSample`, `sampleSize`, `stratumColumn`) and the derivation
  (`transforms`, one kind: `missingValues`).
- `DatasetMaterializer` makes the student's bytes from `(source, spec, seed)`.
  The seed is the per-(student, assignment) seed
  (`APIAssignmentPersonalizationSeed`).
- `DatasetResolver.resolve(manifest:seedHex:sourceDirectory:)` is the one
  call that every delivery path makes: the worker job payload, the browser
  seed endpoint, the editor working copy, the personalization overlay and
  validation.
- Authoring is per assignment: the Files-panel row control, the two
  `/datasets` endpoints and the `set_dataset` MCP tool.
- The diagnostics chips (similarity, drift) and multi-variant validation are
  per assignment.
- Grader-only files are a separate list on the manifest.

The decision in #1434 stands: **datasets stop at the CSV**. No query shim, no
database layer. This plan keeps the boundary server-side. What reaches a
student is still a file under a known name.

### How HLTH 230 (Winter 2027) uses data today

The live course has 25 assignments. Data reaches students in four different
shapes, and only one of them is the dataset feature.

| Assignment | What ships | Shape |
|---|---|---|
| Assignment 4 | `assignment4_vitaldb_cases.csv`, 150 rows per student | dataset (`rowSample`) |
| Lab 9 | `nhanes_bp.csv`, 3000 rows per student | dataset (`rowSample`) |
| Lab 6 | `foodlog.csv`, `bigfoodlog.csv` | plain support file, every student the same |
| Lab 8 | `exercise.csv` | plain support file |
| Assignment 3 | `dbgen.py` | a generator script that makes a patient table at run time |
| Assignment 2 | `generate_reads.ipynb` | a generator notebook |

Nothing links these together. A student's 150 VitalDB rows in Assignment 4
are not related to any rows they saw before. A student cannot find out where
`nhanes_bp.csv` came from, what its columns mean, or under which licence they
may use it. The instructor uploaded each file into each zip by hand, and a
second offering will upload them again.

---

## 2. What is missing, from the course's point of view

1. **No reuse.** The same file is uploaded into each assignment. A fix to the
   file (a column renamed, a bad row removed) is applied once per assignment,
   or missed.
2. **No cohort.** The seed is per assignment, so a student's rows change from
   lab to lab. A course cannot say "these are your patients" and build nine
   labs on them.
3. **No data dictionary and no provenance for students.** The dataset is
   visible only as a file in the editor. Column meaning, units, source and
   licence live in the instructor's head or in a notebook cell.
4. **No way to get your own rows out.** A student who works in RStudio or in
   a local Python has no download of the bytes the grader uses. The support
   file download route exists but no page links it, and it serves the pool,
   not the slice.
5. **No place in the course outline.** Content items can be a reading or a
   link, but a dataset has no entry of its own.
6. **No versioning.** A re-upload replaces the file in place. There is no
   record that Lab 9 was graded against an older file than Assignment 4.
7. **No rollover.** A course clone copies each zip, which works, but there is
   no library to carry forward and no way to see which assignments share a
   file.

---

## 3. Decisions

Each decision gives the choice, the reason, and the alternative that lost.

**D1. The library is per course.** A dataset belongs to one course offering,
like a content item. The alternative, a deployment-wide library, would need
cross-course access rules and would carry data between instructors who do not
share a course. A clone for a new term copies the library (slice 8).

**D2. Attachment copies the pinned bytes into the setup zip.** Attaching a
dataset writes the version's file into the assignment's zip as an ordinary
support file and records the source on the `DatasetSpec`. Nothing downstream
changes: the worker, the browser, the editor, the personalization overlay,
`TestSetupCache`, the version snapshots and the bundle export all keep reading
the zip. The alternative, delivering the file from the library at grade time,
would touch all seven delivery paths and the runner cache key for no gain a
student can see. Disk is not a concern at the sizes in use (a few hundred
kilobytes), and the version blob store already dedupes by content hash.

**D3. A reference is by slug and version, not by UUID.** `DatasetSource` holds
the dataset's per-course `slug` and the pinned `version` number. A slug
survives a course clone and a bundle import without an ID map. The UUID is
the database key only.

**D4. The cohort seed is per (student, course), stored, and derived per
dataset.** A new table holds one random seed per (student, course), with the
same shape and the same race handling as `AssignmentSeedStore`. The effective
seed for a course-scoped spec is `sha256(courseSeed || slug)` as hex. The
alternative, deriving it from an existing assignment seed, fails because every
assignment already has its own seed. The alternative, one course seed with no
per-dataset derivation, would make two datasets of the same row count give the
same row indices, which is a visible pattern.

**D5. Scope is per attachment, and the default is the assignment.** An
attached dataset says whether its slice is `assignment` (today's behaviour) or
`course` (the cohort). The default is `assignment`, so every existing spec
decodes to the bytes it delivers today. The Files-panel control reads "same
rows in every assignment".

**D6. Nested samples come from the materializer as it is.** The partial
Fisher-Yates in `DatasetMaterializer` chooses the first `k` slots, so a
smaller sample from the same seed is a prefix of a larger one. Under course
scope, a lab that gives 100 rows and a later lab that gives 500 rows give the
same first 100 patients. This is a property to pin with a test, not to build.
It does not hold across a change of `stratumColumn` or across transforms, and
the doc says so.

**D7. The data dictionary is instructor prose, checked against the header.**
A version carries the header's columns, inferred when the file is uploaded. The
instructor adds a description and a unit per column. A dictionary entry that
names a column the file does not have is refused at save. The dictionary feeds
the student Data page and `get_dataset`. It does not change grading.

**D8. Licence and provenance are required before students can see a
dataset.** A dataset is `published` only when both fields are non-empty. This
makes the rule in `datasets.md` §"Privacy and governance" (synthetic or
licensed only) a field a reviewer can audit, not a sentence in a doc.

**D9. Students see their own rows, never the pool.** The Data page and the
assignment page link to a download of the student's slice. It is the same
bytes `DatasetResolver` delivers to the grader, made by the same call. Staff
can download the pool. A grader-only file is never on either page.

**D10. One copier owns the clone.** The September audit (item 8 in
`docs/audit-2026-09.md`) found three copy paths with three part lists. The
library is added to `CourseCloneService` and to the bundle in one place each,
and a test asserts that a cloned course's assignments resolve their
`DatasetSource` in the new course.

---

## 4. Design

### 4.1 Core (slice 1)

`Sources/Core/Models/DatasetSpec.swift` gains two optional fields. Both decode
with `decodeIfPresent`, so every stored manifest decodes unchanged.

```swift
/// Where an attached dataset's bytes came from. Nil for a file the
/// instructor uploaded into this assignment by hand.
public struct DatasetSource: Codable, Sendable, Equatable {
    public let slug: String      // per-course unique
    public let version: Int      // the pinned version
}

/// Which seed selects the student's rows.
public enum DatasetSliceScope: String, Codable, Sendable, CaseIterable {
    case assignment   // the per-(student, assignment) seed; the default
    case course       // the per-(student, course) seed, derived per slug
}
```

`DatasetSpec` adds `source: DatasetSource?` and `scope: DatasetSliceScope`
(default `.assignment`). A `scope` of `.course` without a `source` is refused
at save by `DatasetSpecValidation`: a hand-uploaded file has no slug to derive
a seed from.

`Sources/Core/DatasetSeedDerivation.swift`:

```swift
public enum DatasetSeedDerivation {
    /// The seed `DatasetMaterializer` uses for `spec`.
    public static func effectiveSeed(
        spec: DatasetSpec, assignmentSeedHex: String, courseSeedHex: String?
    ) -> String?
}
```

For `.assignment` it returns the assignment seed. For `.course` it returns
`sha256(courseSeedHex + ":" + slug)` as 64 hex characters, or nil when no
course seed was supplied. A nil result means the spec is skipped, and the
student gets the file as shipped, which is the existing "cannot resolve"
behaviour. `Hashing.swift` already holds a SHA-256 helper.

`DatasetResolver.resolve` gains a `courseSeedHex: String?` parameter and calls
the derivation per spec. Every call site passes it (slice 4).

`Sources/Core/Models/DatasetDictionary.swift`: the column list a version
carries.

```swift
public struct DatasetColumn: Codable, Sendable, Equatable {
    public let name: String
    public let inferredType: DatasetColumnType  // integer, number, text, date, boolean
    public var description: String?
    public var unit: String?
}
```

The type is inferred from a bounded sample of rows at upload. It is a hint for
the dictionary, not a contract the grader enforces.

Tests: `DatasetSpec` round-trip with and without the new fields; a stored
manifest from before this slice decodes with `scope == .assignment` and
`source == nil`; `effectiveSeed` is pure and pinned by fixture; two slugs on
one course seed give two seeds; nested samples (D6) pinned.

### 4.2 The library (slice 2)

Two tables, two Fluent models, one service.

`course_datasets`: `id`, `course_id`, `slug`, `name`, `description`,
`provenance`, `licence`, `is_published`, `current_version`, `created_at`,
`updated_at`. Unique on `(course_id, slug)`.

`course_dataset_versions`: `id`, `dataset_id`, `version`, `filename`,
`sha256`, `size_bytes`, `row_count`, `columns_json` (the dictionary), `note`,
`created_at`. Unique on `(dataset_id, version)`.

Bytes live in the content-addressed blob store
(`AssignmentVersionBlobStore`, keyed by SHA-256). A version that has the same
bytes as an earlier one is refused with a message naming that version. A new
version copies the previous dictionary and re-checks it against the new
header; a column that disappeared is dropped from the dictionary and named in
the response.

`CourseDatasetService` owns create, update metadata, add version, publish and
unpublish, delete, and the usage query (which assignments pin which version).
Delete is refused while any assignment's manifest names the slug. Size ceiling
for a version: 16 MB, the same order as the bundle and the divergence
ceiling's reasoning.

Tests: a `.serialized` DB suite in the `with*App` pattern for the service;
slug uniqueness per course; refusal of a duplicate version; dictionary carry
and column drop on a new version.

### 4.3 Attachment and promotion (slice 3)

`attach(dataset:version:to setup:as filename:)` in `CourseDatasetService`:

1. Writes the version's bytes into the setup zip under `filename` (default:
   the version's `filename`), through the same zip helper the support-file
   upload uses, so the version snapshot and the shared directory are rebuilt
   as they are for any upload.
2. Appends a `DatasetSpec` with `source` set and `sampleSize == nil` (the
   whole file) unless the caller gives a sample. The spec then edits through
   every existing control.
3. Runs the existing content-edit effects for a support-file change.

`detach` removes the spec and leaves the file in the zip as a plain support
file, or removes both when asked. `promote(filename:from setup:)` creates a
dataset from a support file already in a zip and sets `source` on its spec, so
the two live HLTH 230 datasets move into the library without a re-upload.

"Newer version available" is a read: the spec's pinned version is lower than
the dataset's current version. `update(to version:)` re-copies and re-runs the
effects. Nothing updates on its own. A closed assignment keeps grading against
what it was validated against, which is the manifest-hash rule from
`datasets.md` §"Why bother".

A file that is attached from the library cannot be deleted through the
support-file delete controls; the row says to detach it instead.

Tests: attach writes the bytes and the spec; the diagnostics chips read the
attached file; detach keeps or removes the file as asked; promote on a live
fixture zip; the "newer version" predicate.

### 4.4 The course cohort (slice 4)

`APICoursePersonalizationSeed` (`user_id`, `course_id`, `seed_value`, unique
on the pair) and `CourseSeedStore.ensureSeed` with the same contract and the
same "never inside a transaction" rule as `AssignmentSeedStore`.

Every `DatasetResolver` call site passes the course seed. The sites, and where
each gets the seed:

| Site | Course seed from |
|---|---|
| `WorkerJobRoutes.buildJobPayload` | `CourseSeedStore.ensureSeed` for the submitter; cached on `SubmissionMaterialization` beside `seedHex` as `courseSeedHex` |
| `BrowserRunnerRoutes` seed endpoint | the same store, the same caching |
| `NotebookWorkingCopyStore.writeDatasetFiles` | the store; the fingerprint in `DatasetMaterializationCache` folds the course seed in |
| `PersonalizationSubstitution.resolve` (the overlay) | passed down by the caller that already has the assignment seed |
| `RunnerValidationService` variants | derived: variant `i` uses `preflightSeed(i)` for both seeds, so a variant stays one synthetic student |
| `datasetDiagnosticsReports` | the preflight seeds, as today; scope does not change the estimate formulas (overlap is a function of selection) |

There is no staff re-seed action today, for the assignment seed or for the
course seed, and this plan adds none. A seed is issued once and kept.

Tests: `MaterializePersonalizedFilesTests` and the browser-runner route tests
gain a course-scoped case; two assignments attaching the same slug with the
same sample give one student the same rows (`PersonalizationDatasetSliceTests`);
a validation variant under course scope grades the variant's rows.

### 4.5 Instructor surfaces (slice 5)

**The Datasets tab** (`/instructor/datasets`, `InstructorTab.datasets`,
`InstructorDatasetsPage`). A list of the course's datasets: name, slug,
current version, size, row count, published state, and the assignments that
use it with their pinned versions. Per dataset: edit metadata and the
dictionary, add a version with a note, publish or unpublish, delete (when
unused). The page follows the titlebar pattern in `docs/ui-design.md` and is
reviewed by `ui-review`.

**The Files panel** gains one control beside the upload: "Attach from the
course library", a select of published and unpublished datasets. An attached
row shows the source (`from VitalDB cases v2`), a "v3 available: update"
action when behind, and a "same rows in every assignment" checkbox for the
scope. The existing sample, stratum and blanking fields stay as they are. The
behaviour lives in `Public/support-files.js`; the markup in `SupportFileRow`.

A promote action on a plain support-file row: "Move to the course library".

Every page change runs `ui-guard` and `ui-review`.

### 4.6 Student surfaces (slice 6)

**The course Data page** (`/:courseKey/data`, `CourseDataPage`), linked from
the student assignments page. For each published dataset: name, description,
provenance, licence, the dictionary as a table, row count, the assignments
that use it, and "Your rows" with a download. The download is
`/:courseKey/data/:slug/mine.csv`: the student's course-scoped slice when the
dataset is attached anywhere with course scope and the whole file otherwise,
with a line that says which.

**The assignment page** (`SubmitPage` and the notebook guide) gets one line
per attached published dataset: "Uses VitalDB cases (v2), 150 of your rows",
linking to the Data page and to a download of the rows this assignment
delivers (`/testsetups/:id/data/:filename/mine.csv`, made by the same
`DatasetResolver` call the grader uses).

A dataset that is attached but not published is listed to staff only.

Tests: the route authorization matrix gains the new routes (students in the
course, staff, nobody else); the download bytes equal the grader's bytes for
the same student; an unpublished dataset is absent from the student page.

### 4.7 MCP (slice 7)

New tools, all course-scoped, with the same gates as content items:

| Tool | Scope | Does |
|---|---|---|
| `list_datasets` | `content:read` | the library with versions and usage |
| `get_dataset` | `content:read` | metadata, dictionary, the first rows of the pool |
| `create_dataset` | `content:write` | from a `sourceUrl` under the SSRF guard (as content attachments), or by promoting a support file of an assignment |
| `update_dataset` | `content:write` | name, description, provenance, licence, dictionary, published |
| `add_dataset_version` | `content:write` | a new version from a `sourceUrl` with a note |
| `attach_dataset` | `content:write` | to an assignment, with filename, version, scope and the sample fields |
| `detach_dataset` | `content:write` | from an assignment |

`set_dataset` gains `scope`. `get_support_files` reports `datasetSource` and
`datasetScope`. `get_assignment` lists attached datasets. The instructions
text in `InitializeTypes.swift` gains a Datasets paragraph. Every tool is
added to `docs/compliance/tool-inventory.md` and to the version-capture
coverage test.

### 4.8 Lifecycle (slice 8)

- **Course clone** (`CourseCloneService`): copy every dataset with all its
  versions. Blobs are shared by hash, so only rows are written. The cloned
  assignments' zips already carry their pinned bytes; their `source` slugs
  resolve in the new course by D3.
- **Bundle export and import** (`CourseBundleRoutes`): add `datasets/` to the
  bundle with a `datasets.json` manifest. Schema version 2 of the bundle.
  Import of a version-1 bundle still works.
- **Storage page** (`AdminStoragePage`): a library row per course.
- **Purge**: the course purge drops the rows; the blob sweep already drops
  unreferenced blobs, and it must count dataset versions as references.

### 4.9 Migration of HLTH 230 (slice 9)

Promote Assignment 4's `assignment4_vitaldb_cases.csv` and Lab 9's
`nhanes_bp.csv` into the library, fill provenance and licence, and publish.
Lab 6 and Lab 8 keep their plain files; the instructor may promote them. No
grading changes: a promoted spec keeps `scope == .assignment` and its sample
size, so every student's rows stay the same.

Docs: a section in `datasets.md` that points here; `CLAUDE.md` reference line;
`docs/architecture.md` one paragraph; `docs/mcp-authoring-roadmap.md` rows.

### 4.10 Optional: `formatNoise` (slice 10)

Already designed in `datasets.md` §"What is NOT built yet". It is
answer-preserving and schema-preserving, so it fits the transform rules and
the row-set theorem. It is independent of the library and can land before or
after it. It is in this plan so the "clean your cohort" lab in the arc below
has a second kind of dirt.

---

## 5. The course arc this makes possible

With the library and the cohort, a course can run one story:

1. **Lab 2**: meet your cohort. 100 of your patients. Describe them.
2. **Lab 4**: your cohort has holes (`missingValues`) and inconsistent
   formats (`formatNoise`). Clean it. The checks are value-based and
   per-student, because the overlay already gives expressions the student's
   rows.
3. **Lab 6**: group and compare within your cohort (stratified, so every
   ward is present).
4. **Lab 9**: fit a model on your cohort; the secret test uses a grader-only
   holdout.
5. **Assignment 4**: write the report on your cohort, with the Data page as
   the citation for provenance and licence.

The same 100 patients from Lab 2 are the first 100 of the 500 in Assignment 4
(D6). A student's numbers differ from every peer's, and their own numbers agree
with each other across the term.

---

## 6. Build order and what proves each slice

Slices 1 to 4 are the foundation and ship with no UI. Slice 5 and 6 are UI.
Slice 7 is MCP. Slice 8 and 9 close the loop. Each slice is one PR with its
own changelog fragment.

| Slice | Files it touches (main) | Proof |
|---|---|---|
| 1 | `Sources/Core/Models/DatasetSpec.swift`, new `DatasetSeedDerivation.swift`, `DatasetDictionary.swift`, `DatasetSpecValidation.swift`, `DatasetResolver.swift` | `CoreTests`: codec back-compat, seed derivation fixtures, nested-sample property, refusal of course scope without a source |
| 2 | new models and migration, `CourseDatasetService.swift` | `APITests`: service suite |
| 3 | `CourseDatasetService.swift`, `ManifestFileHelpers.swift`, `ContentEditEffects.swift` | attach, detach, promote, newer-version predicate |
| 4 | `APICoursePersonalizationSeed.swift`, `CourseSeedStore.swift`, `SubmissionMaterialization.swift`, the six call sites | the delivery-path suites gain course-scoped cases |
| 5 | `InstructorTabs.swift`, new `InstructorDatasetsPage.swift`, `SupportFileRow.swift`, `Public/support-files.js`, `DatasetEditHelpers.swift` | page guard tests, `support-files-datasets.test.mjs`, `ui-review` |
| 6 | new `CourseDataPage.swift`, `SubmitPage.swift`, `NotebookGuide`, new routes | authorization matrix, byte equality with the grader |
| 7 | `Sources/APIServer/MCP/Tools/*Dataset*.swift`, `MCPToolCatalog`, `InitializeTypes.swift` | per-tool suites, output-schema sync, version-capture coverage, compliance inventory |
| 8 | `CourseCloneService.swift`, `CourseBundleRoutes*.swift`, `AdminStoragePage.swift` | clone resolves sources; bundle round trip v1 and v2 |
| 9 | docs, `CLAUDE.md`; the promotion is done through the UI or MCP on the live course | docs-audit clean |
| 10 | `DatasetTransform.swift`, `DatasetTransformApplication.swift` | transform tests, the row-set theorem still holds |

The rules that apply to every slice: Swift Testing only; no new environment
variables; `scripts/format-lint.sh` before each push; the `ui-review` agent on
every view change; `diff-reviewer` before each commit; a changelog fragment per
PR and no version bump.

---

## 7. Non-goals

- A query shim or a database layer (#1434 declined it).
- A deployment-wide or cross-course library (D1).
- Delivery of dataset bytes outside the setup zip (D2).
- A `numericJitter` transform (`datasets.md` says why, permanently).
- Running a generator script server-side to make a version. An instructor
  runs `dbgen.py` where they like and uploads the output as a version.
- Blocking the open of an assignment on a failed validation variant. That
  stays a display, as `datasets.md` decided.

---

## 8. Questions for the maintainer

The plan proceeds on the recommended answers. A different answer changes the
slice it names.

1. **Scope default (D5).** `assignment` keeps every existing spec unchanged.
   Should a dataset attached from the library default to `course` instead,
   since the cohort is the point of the library? Recommended: keep
   `assignment` as the decoded default, but make the Files-panel picker and
   `attach_dataset` default to `course` for a new attachment.
2. **Student download of the pool (D9).** Never for students is the
   recommendation. A course where every student gets the whole file is the
   one case where the pool is the slice, and the download then serves it.
3. **Published by default (D8).** A promoted dataset starts unpublished until
   provenance and licence are filled. The two live datasets would be
   invisible on the Data page until that is done. Fine for a closed term;
   confirm.
4. **Tab name.** "Datasets" on the instructor bar and "Data" on the student
   side. Confirm the words.
5. **Slice 10.** In or out of this arc.
