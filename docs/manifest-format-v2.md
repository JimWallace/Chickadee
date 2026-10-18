# Manifest format v2: design note

Status: **proposed**. Nothing in this note is implemented yet. The phases at
the end give the order of work. Some problems below were first stated too
strongly. The section "Corrections after a read of the code" says which, and
the design and the phases take the corrections into account.

The manifest is `TestProperties` (`Sources/Core/TestProperties.swift`). It is
stored as `test.properties.json` in the test setup zip, in the
`test_setups.manifest` column, in each version snapshot, and in each exported
`.chickadee` course bundle. It replaced the flat key/value `test.properties`
file of Marmoset.

---

## What to keep

The format is sound. These decisions stay in v2:

- **An absent key decodes to its default, and a default value is not
  written.** Old manifests decode. Two writers make the same bytes for the same
  value.
- **One stable encoder.** `ManifestCodec.stableEncoder` sorts keys, so equal
  manifests hash the same (#1526).
- **A runner sees only what it needs.** `runnerSanitized()` removes
  authoring data, so a new server-side enum case cannot break an older runner.
- **A test item is a tagged union** (`{ "type": "family" | "check", "spec": … }`).
- **The language is declared, not inferred** (`docs/language-declaration.md`).

---

## The problems

The manifest grew one field at a time, from about 6 fields to 26. Each addition
was correct on its own. Together they have these problems.

### P1. `schemaVersion` does not change

It is `1` on every manifest. About 20 fields and one shape change
(`patternFamilies` and `notebookChecks` into `testItems`) arrived without a
version change. Migration is done with defaults and special cases in
`init(from:)`. The version number tells a reader nothing.

### P2. One flat struct has three audiences

| Audience | Fields |
|---|---|
| Runner contract | `testSuites`, `timeLimitSeconds`, `makefile`, `requiredFiles`, `starterNotebook`, `language`, `languageDeclared`, `gradingMode`, `submissionMode`, `sections` (literal variables), `globalVariables` |
| Authoring source, server only | `testItems`, `globalExpressions`, `sections[].expressions`, `datasets` |
| Server policy | `achievements`, `disabledBuiltInAwardIDs`, `builtInAchievementsSeeded`, `activity`, `githubSubmission`, `githubStatusChecks`, `githubStarterRepository`, `minimumRunnerVersion`, `graderOnlyFiles` |

`runnerSanitized()` is a hand-written list. Each new field must make the
"runner or not" decision again, and the type does not show the result.

### P3. The types allow states that are not valid

- `TestSuiteEntry.generatedBy` and `generatedByCheck` are two optionals. Only
  a validator stops a writer from setting both.
- `language` and `languageDeclared` hold three states in two fields. A fourth
  combination (a language set, the flag absent) is possible and has no
  meaning.
- `gradingMode`, `submissionMode` and the language can disagree.
  `effectiveGradingMode` and `effectiveSubmissionMode` repair the pair on
  each read.

### P4. `NotebookCheck` holds every option of every kind

There are 10 kinds and about 20 optional fields. The `kind` value selects
which fields apply. A missing required field is a validator error, not a
decode error. The `TestItem.swift` header rejects this pattern for families,
but checks use it.

### P5. The per-test settings occur four times

`tier`, `points`, `hint`, `timeLimitSeconds`, `failureDetail` and `dependsOn`
are on `TestSuiteEntry`, `PatternDefaults`, `PatternCase` (as overrides) and
`NotebookCheck`. A new per-test setting needs four edits, four decoders and
four resolve rules.

### P6. Personalization inputs are in five places

`globalVariables`, `globalExpressions`, `sections[].variables`,
`sections[].expressions` and `PatternFamily.variables`. A literal and an `=`
expression go in different fields. `docs/inputs.md` describes them as one
idea: an input has a name and a value, and the value is a literal or an
expression.

### P7. File roles are in four places

`requiredFiles`, `graderOnlyFiles`, `datasets` and `starterNotebook` each
describe a file in a different way. `datasetSpecsByFile` exists only to
answer "what is this file?" for one of the four.

### P8. Smaller problems

- `dependsOn` has two meanings. In authored form it holds `family:<id>`
  tokens. In persisted form it holds filenames. The type does not show which
  form a value has.
- `builtInAchievementsSeeded` records the state of an editor, not the
  content of an assignment.
- `minimumRunnerVersion` is a string. A typo is found at dispatch, not at
  save.
- The `TestItem.swift` header says that specs expand into `.py` scripts. The
  `NotebookCheckKind` comments describe only pandas and numpy. Both are out of
  date after the multi-language work.

---

## Corrections after a read of the code

A second, closer read of the code found that three problems are smaller
than the first review said.

- **P4 is mostly solved already.** `NotebookCheckKindHandler`
  (`Sources/APIServer/Utilities/NotebookCheckKindHandler.swift`) gives each
  kind one handler for render, label, sidecars and validation, behind an
  exhaustive switch. The flat struct remains, but the per-kind logic is in
  one place. A strict decode would also break the CLAUDE.md rule "never fail
  while grading or rendering": a stored check that is not complete would make
  the full manifest undecodable. Thus D3 is withdrawn.
- **P5 is smaller.** `PatternCase.resolvedTier(defaults:)` and its siblings
  already put the override rules in one place. Only the field declarations
  and decoders repeat. D2 stays in the plan for the shared declarations, but
  it removes duplication, not a defect.
- **P8, the version string, is solved already.** `SetMinimumRunnerVersionTool`
  refuses a string that does not parse, at save. The `SemanticVersion` part of
  D9 is withdrawn.

The v2 envelope (D6 to D8, D10) keeps every current accessor, so its
benefit is mostly a tidier stored JSON. Its cost is a two-release rollout, a
risk to rollback and to bundle import, and changes to some tests. The
maintainer accepted that cost, so it stays in the plan.

---

## Constraints

Each change below must obey these constraints.

1. **Old runners.** Runners update separately from the server. A runner
   decodes `Job.manifest` as `TestProperties`. The runner-facing manifest must
   keep the v1 wire shape until no supported runner predates v2.
2. **Rollback.** The deployer can roll back one release
   (`docs/zero-downtime-deploy.md`). If release N writes v2 and the deployer
   rolls back to N-1, then N-1 must read what N wrote. Thus one release must
   read v2 and write v1. Only the next release can write v2.
3. **Stored data.** The database, version snapshots and exported bundles hold
   v1 manifests. The v1 decoder stays permanently.
4. **Request bodies.** The web editors (`Public/pattern-family-editor.js`,
   the suite editor) and the MCP tools send `PatternFamily`, `NotebookCheck`
   and suite JSON. A wire change to these types is also an API change. v2
   changes the manifest envelope. It keeps the wire shape of `PatternFamily`
   and `NotebookCheck` unless a phase says otherwise.
5. **No new environment variables** (CLAUDE.md).

---

## The design

### D1. Separate the runner manifest (P2)

Add a `RunnerManifest` type in Core. It holds only the runner contract from
the P2 table. `TestProperties.runnerManifest()` makes one.
`Job.manifest` becomes a `RunnerManifest`. Its wire shape is the v1 shape of
the same fields, so an old runner decodes it without a change.

A new `TestProperties` field is then server-only unless a person adds it to
`RunnerManifest`. The compiler shows the decision.

Implemented in phase 2 (`Sources/Core/RunnerManifest.swift`).
`RunnerManifest` encodes and decodes through the `TestProperties` codec, so
its bytes are the bytes that `runnerSanitized()` produced before.
`RunnerManifestTests` keeps the old `runnerSanitized()` body as a fixed point
and checks the bytes against it. `runnerSanitized()` remains, built on
`RunnerManifest`. The worker functions take a `RunnerManifest`, and `Job`
keeps an initializer that takes a `TestProperties`.

### D2. Use one shared settings type (P5)

Implemented in phase 1 (`Sources/Core/TestSettings.swift`).

```swift
public struct TestSettings: Equatable, Sendable {
    public var tier: TestTier
    public var points: Int
    public var hint: String?
    public var timeLimitSeconds: Int?
    public var failureDetail: FailureDetail?
}
```

`TestSettings` is a computed view, not a stored field.
`TestSuiteEntry.settings` (with a setter), `PatternDefaults.settings` and
`NotebookCheck.settings` read the stored fields.
`PatternCase.resolvedSettings(defaults:)` composes the existing
`resolved*(defaults:)` rules, so no override type is necessary.

The stored fields stay, for two reasons. First, the four types have
different decode defaults and encode rules. Second, their encoded bytes feed
`spec_hash` and the runner cache key. A stored `TestSettings` would need a
hand-written encoder in each type only to keep the bytes the same.

### D3. Give each check kind its own payload (P4). Withdrawn: see "Corrections"

```swift
public enum NotebookCheckConfig: Equatable, Sendable {
    case dataFrameShape(variable: String, rows: Int, cols: Int)
    case dataFrameColumns(variable: String, columns: [String], match: ColumnMatchMode)
    case dataFrameEquality(variable: String, expected: FrameComparison)
    case seriesEquality(variable: String, expected: FrameComparison)
    case numericArrayClose(variable: String, expected: [Double], rtol: Double?, atol: Double?)
    case figureCount(minimum: Int)
    case cellContains(text: String, regex: Bool, mustDifferFrom: String?)
    case functionExists(name: String, arity: Int?)
    case variableExists(name: String, type: String?)
    case astStructure(constructs: [String])
}
```

The wire shape stays flat (constraint 4). The decoder reads `kind` and then
the fields that kind needs. A missing required field is a decode error. The
current `NotebookCheck` initializer and optional properties stay as
forwarding members for one release, so callers move at their own pace.

### D4. Tag the origin of a suite entry (P3)

```swift
public enum SuiteEntryOrigin: Equatable, Sendable {
    case handWritten
    case family(id: String)
    case check(id: String)
}
```

Implemented in phase 1 (`Sources/Core/SuiteEntryOrigin.swift`).
`TestSuiteEntry.origin` is a computed property over the two stored optionals.
The sites that now test `generatedBy` and then `generatedByCheck` switch on it
instead. The wire shape does not change.

### D5. Declare the language in one field (P3)

```swift
public enum LanguageDeclaration: Equatable, Sendable {
    case undeclared
    case noLanguage
    case language(AssignmentLanguage)
}
```

Implemented in phase 1 (`Sources/Core/LanguageDeclaration.swift`). The case
is `noLanguage`, not `none`, so that it is not confused with `Optional.none`. `TestProperties.languageDeclaration` is a computed property
over the two stored fields, with a setter that writes both. A recorded
language without the flag reads as `undeclared`, which is the rule that
bundle import and the backfill already apply. The wire shape does not
change. A future v2 could encode it as one key.

### D6. Use one input type (P6)

```json
{ "inputs": [ { "name": "limit", "value": 5 }, { "name": "n", "expression": "seed % 3" } ] }
```

v2 stores `inputs` at the assignment and on each section. Each input has
exactly one of `value` (a literal, which can be `null`) and `expression`; the
reader refuses any other input. In memory, the inputs stay in the v1 fields
(`globalVariables`, `globalExpressions` and the section fields), so readers do
not change. `PatternFamily.variables`
stays literal-only, because a family is also a request body (constraint 4).

### D7. Give each file one role (P7)

```json
{ "files": [ { "name": "main.py", "required": true },
             { "name": "pool.csv", "dataset": { "file": "pool.csv", "sampleSize": 5 } } ] }
```

v2 stores `files` as a list, not a map, so the order of each v1 list
survives. Each entry has a `name` and its roles. The reader refuses a dataset
whose `file` differs from the entry's `name`, and more than one starter
notebook. In memory, the roles stay in the v1 fields (`requiredFiles`,
`graderOnlyFiles`, `datasets` and `starterNotebook`), so readers do not
change.

### D8. Group the policy fields (P2, P8)

v2 nests these fields:

```json
{
  "github": { "submission": true, "statusChecks": true, "starterRepository": "…" },
  "awards": { "achievements": [], "disabledBuiltIns": [] }
}
```

`builtInAchievementsSeeded` moves out of the manifest. The editor can use
"`awards` is present" as the same signal.

### D9. Smaller fixes (P8)

- Two types replace the double meaning of `dependsOn`: `AuthoredDependency`
  (`.script(name)` or `.family(id)`) on specs, and `[String]` filenames on
  persisted entries.
- Correct the stale comments in `TestItem.swift` and `NotebookCheck.swift`.

### D10. Use the version number (P1)

`schemaVersion: 2` marks the D4 to D8 envelope. `TestProperties.init(from:)`
reads `schemaVersion` first and selects a v1 or v2 decoder. The v1 decoder
is the current one and stays permanently. `TestSetupRoutes` and the bundle
importer accept 1 and 2. Each later shape change increments the number.

---

## Phases

Each phase is one pull request. Each phase keeps the build and every test
green.

| Phase | Content | Wire change | Risk |
|---|---|---|---|
| 1 | D9 comments, D2 `TestSettings`, D4 `origin` and D5 `languageDeclaration` as computed properties | None | Low |
| 2 | D1 `RunnerManifest` for `Job.manifest`, same wire shape | None | Medium: the runner decode path |
| 3 | The v2 decoder (D6 to D8, D10). The server reads v1 and v2, and writes v1 | None written | Low |
| 4 | The server writes v2 to storage. Every outward path (runner job, browser, MCP, bundle export) stays v1 | Yes | Medium |
| 5 (v0.7) | Stop the write of the legacy `patternFamilies` and `notebookChecks` mirror | Yes | Low |

Phase 3 must ship in a release before phase 4 (constraint 2).

### What phase 3 built

- `Sources/Core/ManifestV2.swift` holds the v2 envelope (D6 to D8, D10).
  `TestProperties.init(from:)` reads it when `schemaVersion` is 2, and reads
  every other version as v1, as before.
- The in-memory `schemaVersion` is 1 for a value read from v1 or from v2,
  so equal content compares equal whichever form it was stored in. The
  writer decides the wire version, and `TestProperties.wireVersion(of:)`
  reads the version of stored text without a full decode. The v1 writer
  always writes `schemaVersion: 1`.
- A future version 3, read by this release as v1 and written again, would
  become version 1 and lose the fields that v1 cannot hold. Before this
  release, it would also have lost them, but kept its number.
- `TestProperties.v2Envelope()` returns the v2 form, or nil when the v2 form
  cannot hold the manifest exactly. It checks through the encoded bytes,
  because some losses happen only in the encoding. A manifest it refuses
  stays v1 in phase 4. Known refusals: an entry with both generator fields,
  a language without its flag, a file name twice in one list, two file lists
  in a different relative order, and awards without the seeded flag.
- The REST upload accepts version 1 or 2, and stores the result through
  `encodeManifest` (v1). Course-bundle import stores a v2 manifest as v1
  (`storableImportedManifest`), and refuses a v2 manifest that does not
  decode; a v1 manifest is stored byte-for-byte, as before.
- The v2 reader refuses a hand-written document whose meaning is not clear
  (see D6 and D7). This fails only while authoring: nothing stores v2 that
  has not passed it.

### What phase 4 built

- `encodeManifest` (`Sources/APIServer/Models/APITestSetup.swift`) stores
  `v2Envelope()` when it is not nil, and v1 otherwise.
- `encodeManifestV1` and `manifestTextAsV1` give the v1 form for each path
  that sends a manifest out of the server: the MCP manifest resource, MCP
  `get_assignment_version` and course-bundle export. The runner job and the
  browser runner's manifest endpoint were already v1, because both send the
  `RunnerManifest` (`browserRunnerManifestJSON` for the endpoint). Version snapshots and restore copy
  stored text as it is; this release reads both forms.
- `manifestHash` hashes v2 text in its v1 form. A v1 row keeps its old hash,
  and the same content stored as v2 hashes the same, so the retest check
  (`lastRetestedManifestHash`), version de-duplication and the
  materialization key see no change when an edit rewrites a v1 row as v2. A
  no-op edit still rewrites a non-canonical row in the current stable
  encoding, as before; the one new cost is that each runner downloads that
  setup's zip once more, because the download version keys on the bytes.
- **Rollback floor: the phase 3 release.** A release before it reads v2
  without an error but loses the v2-only keys. The blue-green deployer keeps
  the previous colour running on the same database, so phase 3 must be live
  in production, not only released, before phase 4 merges.

### Work for phase 4 (as planned before phase 4)

- **Rollback floor.** Once phase 4 is deployed, a rollback must not go to a
  release before phase 3: no earlier release can read v2.
- `encodeManifest` writes `v2Envelope()` when it is not nil, else v1.
  `TestProperties.encode(to:)` must stay the v1 writer:
  `RunnerManifest.encode` uses it, and that is what keeps the runner wire v1.
- These read the stored text and pass it on without a decode, so each must
  serve v1 or accept v2 on purpose: the MCP manifest
  resource (`MCPResourceProvider`, whose description names v1 keys), bundle
  export, and version snapshots with `RestoreAssignmentVersionTool`.
  `mutateManifestJSON` compares bytes only, so it needs no change.
- `GET /api/v1/browser-runner/testsetups/:id/manifest` serves the
  `RunnerManifest` form (`browserRunnerManifestJSON`), so it is v1 whatever
  is stored. It used to serve the stored text with only `graderOnlyFiles`
  removed, which sent expression source and other authoring data to the
  student's browser; that was fixed on its own, outside these phases.
- `BackfillDeclaredLanguage` edited manifest JSON as a dictionary. It ran on
  every existing database and was deleted in the fifth migration
  consolidation round, so v2 has no migration to accommodate.

### Effect on tests

Phase 1 keeps every current initializer and property, so no existing test
should change. Phase 2
keeps the wire shape, and `Job` keeps an initializer that takes a
`TestProperties`. Phases 3 and 4 would change the tests that assert on
encoded bytes or on a JSON key. Each phase adds new tests: the computed
properties in phase 1, and the runner manifest wire shape in phase 2.

Per the maintainer's standing rule, a change to an existing test is agreed
with the maintainer before it is made.
