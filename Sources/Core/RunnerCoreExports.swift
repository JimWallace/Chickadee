// RunnerCore is the dependency-free, wasm-safe leaf that owns the canonical
// runtime grading model (TestStatus, ScriptOutput, …) and shared logic. Core
// re-exports it so the many `import Core` sites keep resolving those symbols
// unchanged after they were hoisted down into RunnerCore.
@_exported import RunnerCore
