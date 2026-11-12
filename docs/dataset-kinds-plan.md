# Kinds of data in the course dataset library — plan

How the course dataset library
([datasets-course-library.md](datasets-course-library.md)) grows from two
formats (CSV, FHIR NDJSON) to the other kinds of data a health-informatics
course uses, through one component, and what to change now so that a later
kind is an addition and not a rewrite.

Status: **a design study, not built.** It reads the FHIR work on
`claude/fhir-dataset-plan-315ecb` (P1 to P3 of
[fhir-datasets-plan.md](fhir-datasets-plan.md)) and the mini web of PR #2998
(`docs/examples/miniweb/`). Nothing on the FHIR branch is on `main` yet, so
its stored shapes (the migration, the bundle field, the MCP result keys) can
still change at no cost. That fact drives most of §6.

---

## 1. Summary of the recommendations

| Question | Recommendation |
|---|---|
| One component | **`DatasetFormat` stays the one discriminator**, a closed enum stored on the dataset and the spec. Behaviour moves behind one Core protocol, `DatasetFileProfile`, with one conforming namespace per format. The enum has **one** exhaustive switch that returns the profile; presentation switches exhaustively on a `DatasetDescription` enum. A new format fails to compile in those two places and nowhere else. |
| Two axes | A format is a **framing** (how the bytes split into pieces that are copied, never re-encoded: lines, a header plus lines, message blocks, or one document) and a **profile** (what a piece means, what the unit of sampling is, what the summary holds). FHIR NDJSON is line framing with the FHIR profile. |
| Selection | Only line- or block-framed formats can be selected. A single-document format (a JSON array or object, GeoJSON, a binary file) is **shared only**, or is converted at upload to a line form, as a FHIR Bundle is (P4). |
| The unit | Generalize FHIR's patient: a **unit index** is header lines, context lines (in every slice) and units (each a set of lines). A CSV row, a FHIR patient, an HL7 message and a patient in a long-format CSV are all units. A graph node is not, because an edge belongs to two nodes (§7). |
| Storage | One versioned **description** per version (`description_json`, a discriminated `DatasetDescription`), instead of a new column per format. CSV keeps `columns_json`; no data migration. Rename `summary_json` before the branch merges. |
| Bundles and manifests | A general rule instead of a bump per format: `schemaVersion` 3 means "datasets carry `format`", and a reader refuses an unknown format **by name**. A manifest with an unknown format still decodes and delivers the file whole. Both decoders must ship before a third value is ever written. |
| Graphs | The mini web becomes a library dataset as a **shared JSON document**. Selection by subgraph is not worth building: it breaks the lesson's measured claims and has no disjoint split (§7). Per-student variation comes from personalization. |
| Next kinds, in order | (1) a generic JSON document, shared only; (2) "sample by key column" for CSV, which reuses the FHIR unit index; (3) generic NDJSON records. Parquet, images, WFDB signals and SQLite wait (§3). |

---

## 2. What every format must answer

The FHIR plan's §2 table lists every place that reads the bytes. Grouped by
question, each format must answer seven things:

| # | Question | CSV today | FHIR NDJSON today |
|---|---|---|---|
| Q1 | Is this file acceptable, and what does it hold? | `DatasetDictionary.profile(csv:)` → columns, row count | `FHIRNdjsonProfile.profile` → `FHIRDatasetSummary` |
| Q2 | What does the instructor write, and how does it carry to a new version? | prose and unit per column; `carried(from:onto:)`, `editIssue` | prose per type and code, the example pick; `carryingNotes`, `withNotes` |
| Q3 | What is the unit, and what selection is allowed? | row; sample, stratum, partition, transforms | patient (P5); nothing yet |
| Q4 | What is a slice? | `DatasetMaterializer.select` and the transforms | the whole file |
| Q5 | What does an empty slice hold? | the header (`headerOnly`, `header.csv`) | the context lines (P5) |
| Q6 | What do the pages and MCP show? | the column table, rows | the counts, the codes, the example |
| Q7 | Name, extension, media type, count noun | `.csv`, `text/csv`, rows | `.ndjson`, `application/fhir+ndjson`, patients |

Everything else stays format-blind, as the FHIR plan found: the worker, the
runner cache, the seeds, the overlay, storage accounting, and
`DatasetDeliveryMode` (which reads the spec, not the bytes). That boundary is
what makes one component possible. **A format is a Core concern that ends at
the materializer.**

---

## 3. A taxonomy of kinds

| Kind | Example in a health course | Framing | Unit | Selection | Summary / dictionary | Data page | Size reality | Verdict |
|---|---|---|---|---|---|---|---|---|
| Table | vitals, a cohort extract | header + lines | row | sample, stratum, partition, transforms (built) | columns, types, prose, units (built) | column table | KB to a few MB | built |
| Table, long format | ECG or vitals series, one row per (patient, time) | header + lines | **the rows sharing a key column** | sample and partition by key; no stratum at first | the CSV dictionary, plus the key column and the count of keys | column table, "N patients in M rows" | 1 MB per 12-lead 10 s ECG at 500 Hz | next, small (§5) |
| TSV | the same, tab-separated | header + lines | row | as CSV | as CSV | as CSV | as CSV | a CSV dialect, not a format: a delimiter field on the table profile, if asked for |
| Records, NDJSON | a feed of events, de-identified notes | lines | record, or the records sharing a key field | sample by record or key | field paths seen, their JSON types and counts; prose per path; an example | counts, field table, example | 0.5 to 1 KB per record | third |
| FHIR NDJSON | an ED feed | lines | patient + context | P5 | built | built | 6 to 10 MB for 300 patients | built, shared |
| JSON document | the mini web, a lookup table, a code system | one document | none | **shared only** | top-level shape: object or array, entry count, value types, sample keys; prose on the document and on top-level keys | shape, an example entry | 120 KB (mini web) | first new kind (§7) |
| Graph | a referral network, the mini web's links, a citation net | edge-list CSV, or a JSON document | node, but edges span two | **shared** (§7) | node and edge counts, degree range, components | counts, an example node | small | no graph format; a table or a document |
| HL7 v2 | ADT and ORU messages | blocks (MSH to the next MSH) | message, or the messages of one PID-3 | sample by message or patient | message types, segment types, counts | counts, an example message | 1 to 2 KB per message | later, if a course asks; today a CSV fallback (FHIR plan §10) |
| Text corpus | discharge summaries | NDJSON records with a text field | document | sample by document | as NDJSON records, plus token and length ranges | counts, an example document | small | covered by NDJSON records |
| Geospatial | clinic locations, catchments | GeoJSON (one document) or GeoJSON Lines | feature | shared, or sample by feature for GeoJSON Lines | geometry types, bounding box, property keys (a dictionary like a table's) | counts, bbox, example | the boundary files are large | later; shared GeoJSON is just a JSON document |
| Signals, binary | WFDB, EDF | binary, often two files | recording | shared | sample rate, leads, duration | metadata | MBs per recording | defer: binary and multi-file (§6) |
| Columnar | Parquet | binary | row group | shared | schema | schema | compact | defer: no `pyarrow` in the browser kernel (`environment-python.yml`) |
| Images | dermatology, X-ray | binary, many files | image | shared | dimensions, count | thumbnails | the 16 MB cap | non-goal: one file per dataset, text pipeline |
| SQLite | a small clinical database | binary | none | shared | tables and columns | schema | small | defer; a query layer stays declined (#1434) |

Three facts from this table shape the rest of the plan.

1. **The unit is usually a group of lines, not a line.** FHIR's patient, a
   long-format ECG's patient, an HL7 patient and an NDJSON key all have the
   same structure: header lines, context lines and units that are sets of
   lines, each line in at most one unit. That is one materializer, not four.
2. **A single document cannot be selected without re-encoding it**, which the
   FHIR plan forbids (F1). Such a format is shared only, or it is converted at
   upload to a line form, once, so that every later byte is fixed.
3. **Every binary kind is also a multi-file or large-file kind.** The library
   is one UTF-8 file of at most 16 MB, read as a `String` by
   `DatasetResolver` (`String(contentsOfFile:encoding: .utf8)`, which skips a
   file that is not UTF-8). Binary support is a separate design, not a format.

---

## 4. The component

### Decision K1. The enum stays; behaviour goes behind a protocol

The repository prefers an exhaustive enum switch, so a new case fails to
compile until every reader answers. On this branch that holds for the 11
`switch` statements with a `case .fhirNdjson`, but not for the rest: there
are 14 `==` / `!=` comparisons with `.csv` or `.fhirNdjson` (three of them,
the encoders' "write only when not CSV", are fine) and six
`DatasetFormat.fhirNdjson.matches(filename:)` checks (§6, items 4 and 5),
each of which silently treats a third format as one of the two. As
the format count grows, scattered switches also put the same rule in many
files.

The recommended shape keeps the compile-time guarantee in exactly two places:

```swift
// Core. DatasetFormat stays the stored, closed discriminator.
public enum DatasetFormat: String, Codable, Sendable, CaseIterable {
    case csv, fhirNdjson

    /// The one switch on the format for behaviour.
    public var profile: any DatasetFileProfile.Type {
        switch self {
        case .csv: CSVTableProfile.self
        case .fhirNdjson: FHIRNdjsonProfile.self
        }
    }
}

public protocol DatasetFileProfile {
    static var format: DatasetFormat { get }
    static var fileExtensions: [String] { get }   // the first is the default
    static var mediaType: String { get }
    static var capabilities: DatasetCapabilities { get }

    /// Q1: check the file and describe it.
    static func describe(_ bytes: Data) throws(DatasetFileIssue) -> DatasetDescription
    /// Q2: the previous version's prose and picks, on what this file still has.
    static func carrying(_ previous: DatasetDescription, onto next: DatasetDescription, bytes: Data) -> DatasetDescription
    /// Q3, Q4, Q5: nil when the format is delivered whole.
    static func unitIndex(_ text: String) throws(DatasetFileIssue) -> DatasetUnitIndex?
}
```

- **`DatasetDescription`** is an enum with associated values:
  `.table([DatasetColumn], rowCount:)`, `.fhir(FHIRDatasetSummary)`, later
  `.document(JSONDocumentSummary)`. The pages and MCP switch on it
  exhaustively, which is the second compile-time point; presentation is the
  one place that legitimately differs per kind. It carries `unitCount` and
  the count noun, so `InstructorDatasetDetail.countText` and the "300
  patients" labels read it instead of switching on the format.
- **`DatasetFileIssue`** is one Core enum with a case per format
  (`.table(DatasetDictionary.ProfileError)`, `.fhir(FHIRDatasetIssue)`), so
  `throws(DatasetFileIssue)` works through the existential and the service
  maps one error type, as the house rule on typed throws asks.
- **`DatasetCapabilities`** replaces `supportsSelection: Bool`:

  ```swift
  public struct DatasetCapabilities: Sendable, Equatable {
      public let sample: Bool          // sampleSize
      public let partition: Bool
      public let stratum: Bool
      public let transforms: Set<DatasetTransform.Kind>
      public let unitNoun: (singular: String, plural: String)  // as a small struct
  }
  ```

  `DatasetSpecValidation` then refuses a setting with one message template
  ("a FHIR NDJSON dataset takes no stratum column") read from the
  capabilities, in place of the FHIR-specific refusals in `fhirIssue`.
  `DatasetDeliveryMode` reads `capabilities.sample || .partition`. For FHIR in
  P5, `sample` and `partition` turn true and nothing else changes.
- **`DatasetUnitIndex`**: `headerLines`, `contextLines`, `units: [[Int]]` (line
  numbers), in pool order. One generic selector picks unit numbers with the
  existing partial Fisher-Yates (so D6's prefix property holds in units) or
  deals unit `i` to part `i mod N`, and writes header, context and the picked
  units' lines **in pool order, byte for byte**. FHIR P5 is the first user.

**Why not a protocol alone, with no enum.** The format is stored in the
manifest, the bundle and the database, so it needs a closed, `Codable` value
whatever the behaviour looks like. The enum is that value. **Why not the enum
alone, with a switch per operation.** It works at two formats; at five it is
roughly forty switches, each a place to put the same rule a little
differently. One switch to the profile, plus exhaustive presentation, keeps
the "a new format does not compile until it answers" property where it
matters and puts each format's rules in one file.

**Not now: moving CSV onto the unit index.** CSV selection has years of byte
pins (`DatasetAllPartsTests`, the stratified and transform suites). CSV gets a
`CSVTableProfile` that forwards to today's code, and keeps its own selector.
It moves onto the generic selector only if every existing pin passes
unchanged, and only when "sample by key column" needs it.

### Decision K2. Format logic lives in Core, never in RunnerCore

`RunnerCore` must stay Embedded-Swift-compatible, and nothing on the grading
side reads a dataset format: `TestProperties.runnerSanitized()` strips every
`DatasetSpec`, and the runner sees only the materialized file. The profiles,
the descriptions and the unit index use Foundation (JSON parsing) and belong
in `Core`. The server-only parts (the version row, the pages, MCP) stay in
`APIServer`. No format reaches the browser runner except as bytes.

### Decision K3. Bytes at the boundary, text inside

`describe` takes `Data`, so a later binary profile has a place to stand. Text
profiles decode UTF-8 inside and report `.notUTF8` through
`DatasetFileIssue`. The materializer and the resolver stay `String`-based; a
binary format is shared only, which they never select from. Making the
delivery path byte-based is deferred with binary formats.

### Decision K4. A shared JSON reader

Three planned kinds parse JSON: FHIR, NDJSON records and JSON documents. The
FHIR plan (§6) specified a small `JSONValue` enum in Core; P1 uses
`JSONSerialization` with `[String: Any]`. Either works for counting. One
reader should serve all three, and it must also give the **byte range** of a
top-level value, so the JSON-document example (§7) can show one entry of the
file without re-encoding it. The re-indenter from FHIR P1 then formats that
range.

---

## 5. Storage

### The version row

`APICourseDatasetVersion` has `row_count`, `columns_json` (not null) and, on
this branch, `summary_json` (nullable, FHIR only). A column per format does
not scale, and `summary_json` names nothing.

**Decision S1.** `summary_json` holds an encoded `DatasetDescription` for
every format other than CSV, as an envelope:

```json
{ "descriptionVersion": 1, "format": "fhirNdjson", "fhirNdjson": { ... } }
```

**As built (Stage A, 2026-11-12), two deviations from this study:**

- The column keeps the name `summary_json`. The FHIR branch merged and
  deployed with it before Stage A, and a rename during a blue-green deploy is
  not expand-only: the old colour reads the old name. "Summary" names no
  format, so the generic content is enough.
- The payload key is the format's raw value (`fhirNdjson`), not `fhir`, so a
  reader finds it by the `format` it has just read.

A row written before the envelope holds a bare FHIR summary, and the
decoder reads it as `.fhirNdjson`. The MCP dataset result reports the
envelope as `summary` (it was `fhir`).

- **CSV keeps `columns_json`** and a null `description_json`. The model's
  `description` accessor synthesizes `.table(columns, rowCount:)`. Moving
  every CSV version into `description_json` is a data migration with no
  reader that needs it; do it only if `columns_json` ever has to change.
- **`descriptionVersion`** lets a profile change its summary (for example,
  FHIR adds a units-per-code field) by reading old versions tolerantly, with
  no migration. A description that does not decode reads as nil, as
  `summary` does today, and the page says "summary unavailable; upload the
  version again".
- **`row_count` keeps its name and means units**, labelled by
  `unitNoun`. A shared-only format with no unit (a JSON document) stores the
  entry count, which the page labels "entries".

### Bundles

`schemaVersion` 3 exists because a version 2 server would profile NDJSON as
CSV. A bump per format would make every course bundle unreadable on the
previous server each time a format lands.

**Decision S2. Version 3 means "datasets carry `format`".** A version 3
reader refuses a format it does not know, with a message that names it
("this bundle holds a dataset in format 'jsonDocument', which this server
does not support"), not with a `DecodingError`. Today `BundledDataset` decodes
`format` as `DatasetFormat`, so an unknown value fails the whole manifest
with a decoder message. Decode it as a `String` and refuse by name. A fourth
format then needs no version 4. The number moves only when the meaning of an
existing field changes.

### Manifests

**Decision S3. An unknown format in a manifest decodes.** `DatasetSpec`
decodes `format` as `DatasetFormat`, so a manifest that names a format this
server does not know fails `TestProperties` as a whole. Blue-green deploys
run two versions side by side and can roll back (`docs/zero-downtime-deploy.md`),
so an older server can meet a manifest a newer one wrote. The rule in
CLAUDE.md is never to fail while grading or rendering. The fix is a decoder
that keeps the unknown raw value (so a re-encode writes the same bytes and the
manifest hash does not move), delivers the file whole, and makes authoring
refuse to edit that spec. The shape (an optional known format beside the raw
string, or a reserved case that `CaseIterable` consumers skip) is an
implementation choice; the rule is not. This does not bite yet: a server older
than P1 ignores the `format` key, so the first server that can fail is P1
itself, when it meets a third value.

---

## 6. What to change now, ranked

Each item is small, and each is cheaper before the FHIR branch merges than
after.

| Rank | Change | Why now | Size |
|---|---|---|---|
| 1 | **Tolerant decoding (S2, S3).** `DatasetSpec.format` keeps an unknown raw value and delivers whole; `BundledDataset.format` refuses an unknown value by name. | The first server that decodes `format` is this branch. If it ships strict, every later format is a rollback hazard for that server. | a few lines and two tests |
| 2 | **Rename `summary_json` to `description_json` (S1)**, with the envelope; `CheckedUpload` carries one `description` instead of `columns` plus `summary`; MCP `DatasetDTO` reports `description` (discriminated by `format`) beside `columns`, instead of a `fhir` key. | The migration, the column and the MCP output schema are unshipped. After merge each is a migration or an agent-visible change. | a rename across the branch |
| 3 | **`DatasetCapabilities` instead of `supportsSelection`**, read by `DatasetSpecValidation`, `DatasetDeliveryMode`, `DatasetDeals`, `TestProperties.hasPartitionedDatasets`, the Files panel, and `Public/support-files.js` (which today tests `spec.format !== 'csv'` and so hides the sample fields for any future selectable format). The view emits the capabilities as data attributes; the script reads those. | P5 turns FHIR selection on; with a Boolean it flips sample and partition together and rewrites the FHIR refusals. The script's two-valued test is a silent bug for the third format. | small |
| 4 | **Stop inferring FHIR from `.ndjson`.** Promote (`CourseDatasetService+Attachment.swift`, `input.format = … ? .fhirNdjson : .csv`), `SupportFileRow` line 69, `DatasetSpecCheck` (`datasetSpecRefusal`, `datasetFormatRefusal`) and `DatasetSpecValidation.csvExtensionIssue` all read "ends in `.ndjson`" as "is FHIR". Generic NDJSON records use the same extension. Replace with `DatasetFormat.candidates(forFilename:) -> [DatasetFormat]`; promote asks when there is more than one. | Six call sites now; each new format adds more. | small |
| 5 | **Replace the equality branches** (`== .fhirNdjson`, `== .csv`, `!= .csv`) in `DatasetSpecCheck` (lines 58, 72, 87), `CourseDatasetService+Attachment` (238), `InstructorDashboardRoutes+Datasets` (212, 248), `CourseDatasetWriteTools` (326, 351) and `CourseDatasetService+FHIRDictionary` (30) with a capability read or an exhaustive switch on `DatasetDescription`. | They defeat the "does not compile until it answers" rule that the FHIR plan relies on (§6 of that plan). | small |
| 6 | **Introduce `DatasetFileProfile`** with CSV and FHIR forwarding to today's code, and `DatasetFormat.profile` as the one behaviour switch. No behaviour change. | It is the seam items 3 to 5 land on. It can follow the merge, but the earlier it lands the fewer new switches are written. | one PR |
| 7 | **One JSON reader (K4)**, shared by FHIR and the next JSON kinds. | Only when the second JSON kind starts. | defer until then |

**Explicitly deferred:** the generic unit-index selector (it lands with FHIR
P5 and is first used there); moving CSV onto it; "sample by key column";
byte-based delivery; every binary format; multi-file datasets; a graph
format; Parquet; HL7 v2 as a format; any change to `DatasetKind`'s raw values
(`rowSample` stays the stored name even when the unit is a patient; the docs
say "unit sample").

### Blockers in the FHIR work

None blocks generalization outright. Four things would make it more
expensive, and all four are cheap to fix before merge:

1. **The strict `format` decoders** in `DatasetSpec` and `BundledDataset`
   (item 1). This is the one with a production failure mode.
2. **`.ndjson` treated as FHIR** in six places (item 4).
3. **`summary_json` and the MCP `fhir` key** fix a FHIR-specific name into
   the schema and an agent-visible result (item 2).
4. **The two-valued test in `Public/support-files.js`** (item 3).

One drift to note, not a blocker: FHIR plan §6 says JSON is read into a
`JSONValue` enum; `FHIRNdjsonProfile` uses `JSONSerialization`. Either the
plan or the code should say which, before K4.

---

## 7. Graph data and the mini web

### What the mini web is

PR #2998 ships `miniweb.json` (116 pages, 992 links, about 120 KB) and
`miniweb_small.json` (11 pages, the grading web), each **one JSON object that
maps a URL to an HTML page**, plus `miniweb.py`, whose `fetch(url)` looks a
URL up in that object. The graph is not stored as nodes and edges: the links
are `href`s inside the HTML, written in six equivalent forms on purpose, and
extracting and normalizing them is stages 1 and 2 of the lab. Stages 4 and 5
build the graph as a dictionary of sets and run PageRank in plain Python,
which is the only option: `networkx` has no emscripten-forge build
(`environment-python.yml`). So the mini web is a **keyed document
collection** whose graph the student derives. That matters: an "edge list"
format would give away half the lab.

### As a library dataset

Today the PR attaches both files as ordinary support files, which works and
needs nothing. To put the mini web in the library, so that it has a version,
a licence, provenance, a Data page and a clone:

- **A `jsonDocument` format, shared only.** Framing: one document. Q1 checks
  that the file is one JSON value and records its shape: object or array, the
  entry count, the value types, the first keys. Q2: prose on the document and
  on top-level keys (for the mini web, none per key; the description is the
  dataset's own). Q3 to Q5: `unitIndex` returns nil, so the capabilities allow
  nothing and the file is delivered whole through the `shared` link. Q6: the
  Data page shows "116 entries, each a string" and one entry, the
  instructor's pick (one page's HTML), by byte range (K4). Q7: `.json`,
  `application/json`.
- **Two datasets or one.** `miniweb_small.json` is the grading web. It is
  better kept as a plain support file, or as a second library dataset, than
  folded into the first: one file per dataset holds (FHIR plan §12).
  `expected_small.json` is a grading fixture, not a dataset.
- **Class activities.** A shared spec is `isShared`, so the README's optional
  `bestMetric` capstone can rank on it.

The same `jsonDocument` format carries a GeoJSON file, a code-system lookup
or any other JSON a course hands out whole. It is the cheapest new kind and
the first one to build.

### Selection by subgraph

Each way to give students different subgraphs fails a rule the library holds:

| Way | What breaks |
|---|---|
| Sample nodes, keep the induced subgraph | The crawl from `directory.example` no longer reaches most of the sample. The lecture's measured claims (the link farm traps 24, 29 and 41 per cent of the rank at damping 0.5, 0.85 and 0.95; `check_story.py` fails if they stop holding) are properties of the whole web and would differ per student, so the class discussion has no shared numbers. |
| Partition by node | An edge belongs to two nodes, so no assignment of lines to parts is disjoint and covering, which the partition and `allParts` require. |
| A k-hop neighbourhood per student | Neighbourhoods overlap, the D6 prefix property holds in seeds but not in bytes, and the size per student is unbounded. |
| A JSON object at all | Selecting entries re-encodes the document (F1). |

**Decision G1. A graph dataset is shared.** Per-student variation, if wanted,
comes from personalization, which already exists: a per-student seed URL or
query terms, read from the student's seed, over the one shared web. A course
that wants a per-student network gives each student a generated file through
a partition of a **table** of whole small graphs (one row per graph, or a
long-format edge list keyed by graph id, which is "sample by key column",
§3), not by cutting one graph.

**No graph format.** A graph arrives as an edge-list CSV (a table, with a
later "graph view" on the summary if a course wants degree counts) or as a
JSON document. A dedicated format earns its place only if a course needs a
graph summary the table and document profiles cannot give.

---

## 8. Feature interactions

The "Dataset format: `DatasetFormat`" section of
`docs/feature-interactions.md` lists the readers today and ends "a new format
updates every reader above, or says why it does not". With this plan:

- That section gains the **`DatasetFormat.profile` switch** and the
  **`DatasetDescription` presentation switches** as the two places a new
  format must answer, and the rule that no reader compares a format with `==`
  or infers one from an extension.
- `DatasetCapabilities` becomes a shared object with its own row: every
  reader of `supportsSelection` today reads it, and the Files panel script
  reads it from data attributes.
- The tolerant-decode rule joins the manifest rules: an unknown format
  decodes, keeps its bytes and is delivered whole.

---

## 9. Risks and open questions

| Risk | What happens | Mitigation |
|---|---|---|
| The protocol and the enum disagree | `DatasetFormat.profile` returns the wrong type for a case. | A test iterates `allCases` and checks `profile.format == self`. |
| A generic selector changes CSV bytes | Grades shift for existing assignments. | CSV keeps its own selector (K1) until every byte pin passes on the generic one. |
| Context lines leak another unit's data | A format's "context" rule is too loose. | The FHIR plan's strict rule (P3: a closed `Set` of types, a code change with a test) is the template for every profile with context lines. |
| Shared-only kinds grow large | A shared JSON or FHIR file is stored once per setup, but a browser-graded lab downloads it per grade. | The 16 MB cap stands; the authoring note says so per format. |
| A stored description becomes unreadable after a profile change | The Data page loses the summary. | `descriptionVersion` and tolerant reads (S1). |

Open questions for the maintainer:

1. **Tolerant decoding (S3): accept the rule now, on this branch?** It is the
   one change with a production failure mode if skipped.
2. **Rename `summary_json` and the MCP `fhir` key before merge (S1, item 2)?**
   After merge it is a migration and an agent-visible change.
3. **Which kind is next?** This plan's order is the JSON document (for the
   mini web), then sample by key column (for long-format vitals and ECG), then
   NDJSON records. A course need may reorder it.
4. **Should "sample by key column" be a CSV setting or the default reading of
   a long-format table?** A setting is explicit; it adds a field to
   `DatasetSpec` (encoded only when set, as `partCount` is).
5. **Binary data.** Is any course likely to need images or WFDB signals in the
   next year? If not, binary support stays out of scope and the `String`
   delivery path stays as it is.
6. **HL7 v2.** The FHIR plan made it a non-goal with a CSV fallback. Under
   this plan it is a block-framed format with a message unit. Keep it a
   non-goal unless HLTH 230 asks.
