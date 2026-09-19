### Changed

- **A test that needs an interpreter now skips visibly, and CI fails on any
  skip.** 136 execution tests across 21 files returned early from a `guard`
  when their tool was absent, so a lane stayed green having executed nothing
  in that language. That happened three times (Rscript, r-base, lua5.4).
  Each of those tests now carries a `ConditionTrait` (`@Test(Self.requiresLua)`,
  `@Test(.ciOnly)`, `@Test(.requiresRscript)`), so Swift Testing reports the
  skip with its reason in the log and in the xUnit report. Every Swift test
  lane and the nightly coverage run now write that report with
  `--xunit-output`, and the new `scripts/check-no-skipped-tests.sh` fails the
  job on any skip, naming the test and the tool. Four guards stay, each with a
  comment: three per-argument conditions in parameterized tests, and one
  mid-body guard whose first half runs without the tool. No assertion changed.
