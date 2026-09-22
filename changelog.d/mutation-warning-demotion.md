### Fixed

- **Mutation sweep: restore the warning demotion the Swift 6.4 move silently
  removed.** Half of the weekly sweep's shards had been dying twelve minutes
  into their build, reporting zero mutant outcomes. Muter's `RemoveSideEffects`
  operator deletes the USE of a binding and leaves the binding, the package
  treats every warning as an error, and schemata put every mutant in one binary
  — so one such mutant fails the build of the whole copy. `-Xswiftc
  -no-warnings-as-errors` had answered that until Swift 6.4 made SwiftBuild the
  default SwiftPM build system, which emits `-Xswiftc` flags *before* each
  target's own `swiftSettings`; the argument was still accepted and still on
  every command line, with no effect. The demotion is now a toolset
  (`Tools/mutation/warnings-not-errors.json`), measured to win under both build
  systems.
- **Mutation sweep: prove the demotion before spending the build, and stop
  misnaming the cause when a run yields nothing.** `scripts/mutation-run.sh`
  compiles a throwaway package carrying the same setting and an unused binding,
  using the very arguments it will hand to Muter, and refuses to go on if the
  warning still lands as an error — five seconds against the shard's twelve
  minutes; `--check-build-flags` runs just that check and is now a row in the
  Swift-upgrade gauntlet. A run that produces no outcomes reports a build
  failure as a build failure, where it used to blame the insertion patch
  whatever had happened.
