### Fixed

- **The runner's compile-and-exec capability probe asks the language for its
  probe program** instead of hardcoding a C++ source file. The old form was
  correct while C++ was the only language needing it and a silent failure for
  the next: C++ source handed to a different compiler fails, the language is
  never advertised, and its jobs queue forever with no error — the worse
  direction of the capability gate. The mapping is exhaustive, so an eighth
  language must answer.
- **The probe now has tests**, in both directions: a usable work root advertises
  C++, and one the probe cannot use withholds C++ while leaving every other
  language advertised.
- **The custom-script scaffold's comment no longer claims a generality it does
  not have.** `capabilityRequiresExecutableOutput` means "grading execs a file
  it just produced", which is C++ alone — Java is compiled and answers `false`,
  so it takes the interpreted branch. Recorded rather than guessed at, and the
  C++ compile line now passes `-std=c++20` to match what generated cases use.
