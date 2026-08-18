### Changed

- **The mutation-testing question got a precise trigger, and a measured answer.**
  The Muter spike closed negative but could not say *why*, leaving "watch for a
  release mentioning schemata or Swift 6.3 support" as the revisit condition.
  There is no version boundary: Muter `99624ec` (PR #302, "Prevent memory
  exhaustion on large codebases") made discovery stop handing its parsed trees to
  `ApplySchemata`, which now re-parses each file — and since the schemata are
  keyed by SwiftSyntax nodes, which hash by identity, no key can ever match a
  re-parsed tree and no mutant is ever inserted. Restoring that one cache takes
  the probe from a fabricated 0% to a correct 66%. Both failures are already
  filed upstream (muter#307, muter#308, both open), so the trigger is now a
  single watchable issue rather than a release feed, and the probe workflow says
  so at the point of dispatch.
- **A patched Muter was then run against real source.** Four `RunnerCore` files,
  763 LOC: **69% — 88 mutants killed, 39 survived, zero build errors, 46
  minutes**, the first mutation score against Chickadee source that measures
  anything. It surfaced seven specific gaps, including an entirely untested
  suite-runner event stream (deleting `.missingScript` would make a missing
  script invisible in both the outcome and the log), untested BOM/whitespace
  trimming and content-based Python classification, and no test parsing a
  numeric exponent in a result footer. `docs/mutation-testing-pilot.md` records
  the costs (one mutant per 6 LOC, so a whole-tree run is ~10,000 mutants), the
  survivors worth chasing versus the ones that are unkillable by construction,
  and the argument for and against a standing monthly run.
