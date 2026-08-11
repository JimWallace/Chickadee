### Fixed

- **The vendored-kernel guard stopped reading the language descriptors, and CI
  had been red on `main` for five releases.** `check-xeus-vendored.sh` derives
  which kernels to expect from `LanguageDescriptor`, but it paired them by line
  PROXIMITY — the nearest preceding `case .X:` owned the next `kernelName:`.
  When #1330 hoisted each descriptor into its own `static let`, the six
  consecutive `case .X: return Self.XDescriptor` lines left `.racket` current,
  the first kernel name found (`xpython`) was attributed to it, and `xr`, `xlua`
  and `xoctave` were discarded — so the guard reported three of the four
  vendored kernels as claimed by no language, and mapped the fourth to the wrong
  one. The vendored tree was healthy throughout; only the parse was wrong. It
  now reads the language set from the exhaustive `descriptor` switch and each
  language's own descriptor literal, and refuses to proceed on a descriptor it
  cannot classify — a partial derivation was previously indistinguishable from a
  complete one, which is the same fails-open shape the guard exists to catch.

- **The JupyterLite guards now run on pull requests, not only on `main`.** Their
  path filter skipped them for any PR touching no JupyterLite file while still
  reporting the job green, and `push` to `main` always counted as relevant — so
  the guards effectively ran only after merge. That is why the broken derivation
  above was invisible: every PR was green, every push to `main` was red, and the
  two were never running the same check. The filter was written to skip an
  expensive rebuild that no longer exists (CI cannot rebuild the kernels; the
  committed bytes are authoritative), so it was saving one Python setup and
  costing the merge-time signal. All three guards run unconditionally now; they
  take well under a second.
