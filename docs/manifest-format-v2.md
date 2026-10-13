# Manifest format v2: design note

Status: **proposed**. Nothing in this note is implemented yet. The phases at
the end give the order of work.

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

### D2. Use one shared settings type (P5)

```swift
public struct TestSettings: Codable, Equatable, Sendable {
    public var tier: TestTier
    public var points: Int
    public var hint: String?
    public var timeLimitSeconds: Int?
    public var failureDetail: FailureDetail?
}

public struct TestSettingsOverride: Codable, Equatable, Sendable {
    public var tier: TestTier?
    public var points: Int?
    public var hint: String?
    public var timeLimitSeconds: Int?
    public var failureDetail: FailureDetail?

    public func applied(to base: TestSettings) -> TestSettings
}
```

`TestSuiteEntry`, `PatternDefaults` and `NotebookCheck` hold a
`TestSettings`. `PatternCase` holds a `TestSettingsOverride`. The wire shape
stays flat: each type encodes the settings keys at its own level, as today.
The current initializers and property names stay as forwarding members, so
call sites do not change.

### D3. Give each check kind its own payload (P4)

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

`TestSuiteEntry.origin` replaces the two optionals in memory. On the wire,
v1 writes `generatedBy` or `generatedByCheck` as today. v2 writes
`"origin": {"family": "<id>"}`.

### D5. Declare the language in one field (P3)

```swift
public enum LanguageDeclaration: Equatable, Sendable {
    case undeclared
    case none
    case language(AssignmentLanguage)
}
```

The in-memory model uses this enum. v1 encodes it as the two current fields.
v2 encodes `"language": "<name>"` or `"language": "none"`. An absent key is
`undeclared`. The runner manifest keeps the two v1 fields (constraint 1).

### D6. Use one input type (P6)

```swift
public struct Input: Codable, Equatable, Sendable {
    public var name: String
    public var value: InputValue
}

public enum InputValue: Equatable, Sendable {
    case literal(JSONValue)
    case expression(String)
}
```

v2 stores `inputs: [Input]` at the assignment and on each section. The
sanitizer removes `.expression` values in one place. `PatternFamily.variables`
stays literal-only, because a family is also a request body (constraint 4).

### D7. Give each file one role (P7)

```swift
public struct ManifestFile: Codable, Equatable, Sendable {
    public var required: Bool
    public var graderOnly: Bool
    public var starterNotebook: Bool
    public var dataset: DatasetSpec?
}
```

v2 stores `files: [String: ManifestFile]`. The computed properties
`requiredFiles`, `graderOnlyFiles`, `datasets` and `starterNotebook` stay, so
readers do not change.

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

- `minimumRunnerVersion` decodes into a `SemanticVersion` value. A string
  that does not parse is refused at save.
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
| 1 | D9 comments and `SemanticVersion`, D2 `TestSettings`, D3 `NotebookCheckConfig`, D4 and D5 in memory only | None | Low |
| 2 | D1 `RunnerManifest` for `Job.manifest`, same wire shape | None | Medium: the runner decode path |
| 3 | The v2 decoder. The server reads v1 and v2, and writes v1 | None written | Low |
| 4 | The server writes v2 to storage and bundles. The runner manifest stays v1 | Yes | Medium |
| 5 (v0.7) | Stop the write of the legacy `patternFamilies` and `notebookChecks` mirror. Remove the forwarding members from D2 and D3 | Yes | Low |

Phase 3 must ship in a release before phase 4 (constraint 2).

### Effect on tests

The phases keep the current initializers and properties as forwarding
members. Thus most tests compile without a change. These tests change:

- Tests that assert on encoded bytes or on a JSON key (for example, a test
  that finds `"generatedBy"` or `"requiredFiles"` in the output) change in
  phase 4.
- Tests that construct a `NotebookCheck` that is not valid for its kind
  fail in phase 1, because D3 refuses it at decode. Each such test shows
  whether the test or the validator was wrong.
- New tests are added for each phase: the v1 and v2 round trip, the
  v1-to-v2 migration, the runner manifest wire shape, and the decode errors
  from D3.

Per the maintainer's standing rule, a change to an existing test is agreed
with the maintainer before it is made.
