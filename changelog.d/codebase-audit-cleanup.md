### Fixed

- **A test script that emits CRLF keeps its JSON footer, and its partial-credit
  score with it (#1457).** `"\r\n"` is one Swift `Character`, so RunnerCore's
  split on `"\n"` never split Windows line endings: the footer was invisible,
  `shortResult` became the whole raw stdout, and `score` fell back to the
  exit-code default. Every line split in RunnerCore now goes through one
  scalar-based `splitLines` that treats `\n`, `\r\n` and a lone `\r` as a line
  break — the footer, the extensionless-Python content sniff, the shebang
  reader, and notebook extraction alike. Native and browser graders share the
  fix; the browser gets it on the next wasm re-vendor.
- **A Java author's custom-script scaffold compiles with `javac` and runs the
  class, rather than `java solution.java` (#1394).** The scaffold picked its
  compile branch from `capabilityRequiresExecutableOutput`, which is true of C++
  alone, so Java rendered in single-file source mode — which breaks the moment
  a submission needs a second file. `LanguageDescriptor` gains
  `gradingCompilesBeforeRunning`, answered for every language, and the scaffold
  keys on it first and the exec fact second. The C++ shape now compiles at
  `-O0`, matching the generated cases.

### Changed

- **Mutation-sweep survivors from the 2026-09-08 tally (#1509) turned into
  tests or simplifications.** `inferredCollectionStatus` (the one-word job
  status the runner reports) is pinned by tests for the first time, and the
  notebook shape check's `is [[String: Any]] || is [Any]` — whose first disjunct
  could never change the answer — is `is [Any]`.

### Removed

- **Seven unreferenced declarations** found by a whole-tree reference scan:
  `authorizationServerMetadataURL`, `SecurityHeadersMiddleware.defaultContentSecurityPolicy`
  (its comment claimed tests pinned it; none did), `didRecord`,
  `drainGraceSeconds`, `OIDCEnvConfig.hasCredentials` (its comment claimed a
  startup warning read it; the warning reads the secret directly),
  `ObservabilityEvent.jobRecovery` (never emitted), and
  `LanguageProse.mustDeclareDisplayNames`.
