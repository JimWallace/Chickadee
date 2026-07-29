### Added

- **Design review of the language-dispatch surface, and its accepted fixes.**
  `docs/language-handling-review.md` answers the review brief from PR #1234;
  the maintainer accepted the concrete recommendations and they land in the
  same PR: R notebook extraction hoisted into RunnerCore (`extractR`, exported
  through the wasm bridge as `runnerExtractR` so the browser runner shares the
  worker's marker-emitting implementation and its verbatim `extractRCell` stub
  is gone); the browser `R_KERNEL_NAMES` copy is now a generated fenced block
  (`scripts/generate-js-constants.sh`, checked in CI, replacing the regex-parse
  drift test); the script-extension→language sniff is consolidated into
  `AssignmentLanguage.scriptExtensions` / `init?(scriptExtension:)`; the
  no-notebook `resolve(manifest:)` spelling is retired from Core's public API;
  and the boolean-shaped language tests on output-producing paths are
  exhaustive switches. Also corrects the stale `CLAUDE.md` claim that the R
  pattern-family / notebook-check renderers are deferred (they shipped in
  #1207). No behaviour change for existing assignments: extracted, generated,
  and staged bytes are identical.
