### Added

- **A runbook for Swift toolchain upgrades, and a Routine that starts one.**
  `docs/swift-toolchain-upgrades.md` records how the 6.3 to 6.4 move was done
  and turns it into a repeatable job: where every toolchain pin lives and how to
  find them, the five traps that each cost a day (the mirror bootstrap failing
  the first CI run, the browser wasm re-vendoring unattended on merge, a
  successful link that still gives a broken binary, attribution by control, and
  the Ubuntu distro bump that fails silently because interpreter suites skip
  rather than fail), the bar a new language feature must clear before the
  codebase adopts it, and the verification gauntlet with the counts to record.
  It carries the agent prompts for both halves. A semi-annual Routine fires on
  15 March and 15 September, checks swift.org against the tools version in
  `Package.swift`, and stops without opening anything when there is no new
  release.
