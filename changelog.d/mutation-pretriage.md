### Added

- **A first reading of each mutation survivor.** After the weekly sweep, `mutation-pretriage.yml` has a model (the sonnet family) read each survivor against the source, the tests and the equivalent-mutant ledger, and comment on the sweep issue: a likely gap with a test sketch, a likely equivalent with a draft argument, reachable only from `APITests`, or unclear. The readings are unverified; `docs/mutation-triage.md` still governs. It writes no tests.
