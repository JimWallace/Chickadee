### Changed

- **Each interpreter trait is declared once per test target (#1946).**
  Seventeen suites declared their own `requiresLua`, `requiresPython3`,
  `requiresGpp`, `requiresJavac`, `requiresOctave`, `requiresRacket` or
  `requiresRscript`, and most of them probed through the uncached
  `toolIsAvailable`. The traits are now in `HostConditionTraits.swift`
  (APITests) and `WorkerTestSkip.swift` (WorkerTests), on
  `cachedToolIsAvailable`, and 117 tests use them. The probe cache is now
  keyed by the whole command, because `lua` answers `-v` and fails
  `--version`. The pandas and matplotlib traits stay local.
