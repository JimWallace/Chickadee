### Fixed

- **The mutation sweep's baseline suite no longer fails before anything is
  mutated.** Muter writes a preamble — including `import class
  Foundation.ProcessInfo` — into every file it will mutate, *before* running the
  suite unmutated to establish a baseline. `ZipProcessEnvironmentTests` reads
  `Sources/Core/ZipArchiver.swift` and `ZipProcessSerialization.swift` and scans
  them for `Process(` constructions, so the preamble tripped it: one test, two
  files, exactly the two failures that aborted every shard of run 2 after 13–22
  minutes of work. It is skipped now — a guard asserting on the *text* of a file
  under mutation cannot coexist with mutation, and has no mutants worth killing
  anyway.
- **A sweep where every shard reports "no mutant outcomes" is no longer green.**
  The shards uploaded reports; the reports said nothing was mutated; the
  aggregator parsed zero survivors and called it a clean sweep. It now treats a
  report with no outcome table as a failed shard rather than an empty one.
