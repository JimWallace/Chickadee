# Core

Shared models and types for the server (`APIServer`) and the runner
(`chickadee-runner`). It imports no Vapor symbol. Every type is `Codable` and
`Sendable`. It re-exports `RunnerCore`, the grading core that also compiles to
WebAssembly, so both targets and the browser grader see one set of grading
types.

## What lives here

The rule is **what the runner links or decodes**: a type belongs in Core when
`chickadee-runner` reads it from a job, a manifest or a result, or calls it
while grading. The runner is a separately deployed binary that upgrades on its
own schedule, so every type here is a wire contract between two versions.
"Anything Vapor-free" is not the rule; it has no stopping point.

By that rule Core holds the test-setup manifest (`TestProperties`) and every
type it decodes, the assignment languages and the `LanguageDescriptor` table,
the job and result types, pattern families and notebook checks, the
personalization runtimes the runner stages, and the zip helpers both targets
spawn.

## Debt: server-only files

Measured by type name (2026-10, #1723), `Sources/Worker` references nothing
from 33 files here, 5,021 lines, none of them a member of `TestProperties`,
`Job` or a result type. They compile into the runner for nothing. Each group
is a move to `APIServer`, one PR per group, each with a struct test suite that
needs no app; do not add a sixth group. The owning audit sweep is named.

- **Avatars**, 838 lines: `AvatarSpec`, `AvatarMarkup`, `AvatarHandle`,
  `AvatarCustomization` (sweep 8, #1689).
- **Dataset materialization and diagnostics**, 1,155 lines:
  `DatasetMaterializer`, `DatasetDivergence`, `DatasetDiagnostics`,
  `DatasetSpecValidation`, `DatasetTransformApplication`, `DatasetResolver`.
- **Course model and bundle format**, 797 lines: `CourseBundleManifest`,
  `AcademicTerm`, `SlipDayPolicy`, `AssignmentVisibility`, `CourseRole`,
  `ContentAttachment`, `SolutionVisibility`, `ContentItemKind`, `ContentLink`,
  `CourseEnrollmentMode` (sweeps 4 and 7).
- **Authoring renderers and drivers**, 1,408 lines: `NotebookFunctionScanner`,
  `JSONValueCppLiteral`, `JSONValueJavaLiteral`, `JSONValueRacketLiteral`,
  `CStyleStringEscaping`, `LuaPersonalizationRuntime`,
  `OctavePersonalizationRuntime`, `RPersonalizationRuntime`. `JSONValue.swift`
  mixes the shared model with four more renderers and splits the same way.
- **Activities and achievements**, 588 lines: `Tournament`,
  `AchievementEvaluation` (sweep 5, #1686).
- **Other**, 235 lines: `LTIRoleMapping`, `LineDiff`, `RunnerResult`.

All four of `AcademicTerm`, `Avatar*`, `Tournament` and `LTIRoleMapping`
arrived since August 2026 by copying the pattern this section exists to stop.

Read [CLAUDE.md](../../CLAUDE.md) for the design decisions and
[docs/architecture.md](../../docs/architecture.md) for the system shape.
