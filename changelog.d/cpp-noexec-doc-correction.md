### Changed

- **Corrected the C++ `noexec` postmortem in `docs/cpp-support.md`.** It said
  no C++ assignment could be graded in production. That was true of the moment
  it was measured — the one runner hardened with a `noexec` `/tmp` was also the
  only one new enough to advertise `cpp` — but not of the system: a second
  runner has a writable, exec-capable work root and grades C++ correctly. The
  bug was claim-order-dependent grading across a non-uniform fleet, which is
  what `RunnerLanguageGate` exists to eliminate, and is why the fix belongs in
  capability discovery rather than an operator runbook. The original conclusion
  came from a probe that filtered the mount table to `/` and `/tmp`; the full
  table is now recorded, along with the v0.5.33 production confirmation that
  the hardened runner drops `cpp` from its profile while keeping every other
  language.
