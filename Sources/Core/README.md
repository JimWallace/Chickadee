# Core

Shared models and types for the server (`APIServer`) and the runner
(`chickadee-runner`). It imports no Vapor symbol. Every type is `Codable` and
`Sendable`. It re-exports `RunnerCore`, the grading core that also compiles to
WebAssembly, so both targets and the browser grader see one set of grading
types.

What lives here: the test-setup manifest (`TestProperties`), the assignment
languages and the `LanguageDescriptor` table, the grading result types,
pattern families and notebook checks, the personalization runtimes, course
bundles, achievements, class activities, and the zip helpers both targets
spawn.

Read [CLAUDE.md](../../CLAUDE.md) for the design decisions and
[docs/architecture.md](../../docs/architecture.md) for the system shape.
