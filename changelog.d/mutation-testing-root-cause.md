### Changed

- **The mutation-testing question got a precise trigger.** The Muter spike closed
  negative but could not say *why*, leaving "watch for a release mentioning
  schemata or Swift 6.3 support" as the revisit condition. There is no version
  boundary: Muter `99624ec` (PR #302, "Prevent memory exhaustion on large
  codebases") made discovery stop handing its parsed trees to `ApplySchemata`,
  which now re-parses each file — and since the schemata are keyed by SwiftSyntax
  nodes, which hash by identity, no key can ever match a re-parsed tree and no
  mutant is ever inserted. Restoring that one cache takes the probe from a
  fabricated 0% to a correct 66%, measured. The condition for re-running the
  probe is now a single upstream issue (muter#307, open, patches offered and
  unmerged) rather than a release note, and the workflow says so at the point of
  dispatch. `docs/handoff-mutation-testing.md` and `docs/mutation-testing-spike.md`
  carry the evidence, including why Muter's own suite could not catch it — its
  rewriter test rewrites the same tree it read, and the five tests shipped with
  the breaking commit assert a constant.
