### Added

- **Tests for eight Core invariants the mutation sweep found unpinned.** The
  2026-08-19 sweep (run 32265903112) reported 31 surviving candidates across
  them; each was confirmed SURVIVED against the run record before a test was
  written and KILLED after, and every kill names the suite that added the
  assertion. Two further survivors turned out to be Muter re-emitting the
  original statement — see the verifier change below.
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
  - `CourseRole`'s `<` — the relation every `requireCourseRole(atLeast:)` gate
    resolves to — and `WorkerHMACSigning.constantTimeEquals`, the comparison
    every runner request is admitted by, were both in that same
    APITests-only class. Each now has assertions beside the type, including an
    RFC 4231 vector for the HMAC itself.
  - `renderInputsFile`'s Racket form had no assertion anywhere, and a surviving
    mutant emitted an unterminated `(define ck-inputs (hash` for an assignment
    with no personalization inputs — a read error on every generated test, for
    every student. Pinned by byte, plus an `allCases` property (balanced
    delimiters, header present, final newline) that a seventh language inherits
    without editing the file.
  - `TestOutcomeCollection`'s output budget is now split by a named
    `outputCarrierCount`. The count was an inline expression inside the
    per-carrier arithmetic, and the halving loop that follows absorbs an
    off-by-one — the result still fits the budget, it just keeps roughly twice
    or half as much of a student's output as it should — so no assertion made
    from outside could see it.

### Changed

- **`Tools/mutation/verify-survivor.py` reports `INERT`.** Muter's `SwapTernary`
  sometimes re-emits the original statement unchanged; `report.py` already
  quarantines those out of a run's survivor list, but the verifier reads a
  record directly, so it would apply an unchanged file, run the suite for two
  minutes, and report `SURVIVED` — "nothing detects this change", about a change
  that was never made. Two survivors in run 32265903112 were exactly this.
