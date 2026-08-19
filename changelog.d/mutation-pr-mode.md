### Added

- **Mutation testing now also runs per pull request, over just the files that PR
  changed.** The weekly sweep answers "how strong is the suite over this target";
  this answers "did the tests arriving with this change actually pin the behaviour
  it adds" — cheaper to ask and far cheaper to act on, since the author still has
  the code in mind. At one mutant per 6 lines a 60-line diff is roughly ten
  mutants and a couple of minutes. It is a report, never a gate: `continue-on-error`
  means a broken Muter or a red baseline cannot fail somebody's PR, and if it
  covers only part of a large diff it says so rather than implying the rest was
  clean.
