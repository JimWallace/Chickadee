### Changed

- **Language dispatch is compiler-enforced, so a third language can't silently
  inherit Python's or R's behaviour.** `AssignmentLanguage` is threaded through
  98 references across 32 files, and almost all of them are either generic or
  exhaustive `switch`es that fail to compile when a case is added — which is the
  point of the design. The exceptions were boolean tests (`if language ==
  .python`, `language == .r ? … : …`) that compile fine with a third case and
  route it down whichever branch it happens to fall into.

  Each remaining one was inverted so the *language* answers the question instead
  of the call site testing it, as a property on `AssignmentLanguage` with no
  `default:` arm: `kernelEnvironmentFileName`,
  `missingDependencyFailureDescription`, `runnerProvidedModules`,
  `studentModulePrefixes`, `supportFilesPathEnvironmentVariable`. Behaviour is
  unchanged — the same strings and sets, reached a different way.

  `AssignmentLanguage.default` is a genuine correction rather than a renaming.
  Resolution asked `manifestOnly == .python` when it meant "did resolution fall
  back?" — the same answer today, and the opposite answer with a third language,
  where it would stop consulting the notebook kernelspec for an assignment that
  had resolved positively.

  Not fixed, and now marked at the site: `shouldNormalizePythonSubmission` is a
  normalization strategy shaped as "R, or else Python", whose Python branch is
  reached by falling through content probes rather than by naming Python. It
  cannot be inverted the same way; giving each language a normalization strategy
  is an artifact rather than an edit. `docs/language-handling-review.md` §4
  records the closed census and this one exception.
