### Fixed

- **Adding or removing a raw script no longer un-declares the assignment's
  language.** The add-script and remove-script manifest rebuilds preserved
  `language` but dropped `languageDeclared`, so one script edit through the
  suite editor turned a deliberate "None" declaration back into "nobody has
  been asked" — the exact conflation the declaration rule exists to remove.
  Both rebuilds now thread the flag, like the pattern-family rebuild always
  did, with a regression test covering the declared-None round-trip.

### Removed

- **The single-implementation `AuthProvider` protocol (#449).** `LocalAuthProvider`
  is now a plain struct called directly from the login route; the protocol,
  the `Application.authProvider` storage seam, and its eager bootstrap wiring
  carried abstraction for a polymorphism that never existed (SSO login is not
  username/password-shaped and never went through it, and no test mocked it).
- **Four dead functions.** `updateManifestLanguage` (superseded by
  `mutateManifest`-based edits, and it dropped `languageDeclared` on rebuild —
  the same defect fixed above, waiting in a function nothing called),
  `clearManifestLanguage` (superseded by `declareManifestLanguage(nil)`; its
  doc comment cited the deleted `rederive` mechanism), `cppIdentifier` (unused
  wrapper over `isValidCppIdentifier`, which every caller uses directly), and
  `racketSubmissionModulePath` (submission module loading lives in
  `test_runtime.rkt`, which builds its own `(file …)` path).
- **Two dead stylesheet rules.** `.test-output-panel` and `.test-output-heading`
  were referenced by no template, page script, or JS-built markup; the live
  `test-output-*` family (`-row`, `-details`, `-pre`, `-pre-wide`) is untouched.
