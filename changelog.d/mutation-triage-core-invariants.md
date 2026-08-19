### Added

- **Tests for four Core invariants the mutation sweep found unpinned.** The
  2026-08-19 sweep reported 23 surviving candidates across four sites; each was
  confirmed SURVIVED against the run record before a test was written and KILLED
  after.
  - `DatasetOverlap.worstPairSharedRows` was asserted only as
    `>= expectedSharedRows`, which equality satisfies — five separate mutants
    collapsed the extreme-value estimate onto the mean and survived, every one
    of them reporting "the unluckiest pair shares the average amount". The
    estimate is now pinned to its documented closed form, with the two
    degenerate inputs (a class of one, a whole-file sample) stated as the cases
    where the mean *is* the honest answer.
  - `NotebookFunctionInfo`'s decoder realigns a `paramTypes` / `paramHasDefault`
    array whose length disagrees with `paramNames`; nothing asserted it from
    either side, so the mutants that discard a correct array and keep a
    wrong-length one went unnoticed. The scanner's identifier-start rule is
    pinned too: a parameter may begin with `_` and may not begin with a digit.
  - `PatternCase` applies the same alignment rule to `argsProvided` /
    `argVarRefs`. It was exercised only from `Tests/APITests`, which the sweep
    does not run — and a Core model invariant pinned solely by an APIServer
    renderer suite is unpinned for every other consumer.
  - `ZipProcessSerialization`'s process-wide lock had no mutual-exclusion test:
    deleting either `lock()` call left the whole suite green while restoring the
    Foundation `Process` spawn race. The EFAULT retry's condition is now pinned
    by domain and by code separately, so retrying the wrong failure is a test
    failure rather than a silent 10 ms tax on the notebook-open path.
