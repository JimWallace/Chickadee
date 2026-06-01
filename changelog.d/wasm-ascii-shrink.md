### Changed

- **Leaner Embedded-Swift wasm runner.** `RunnerCore`'s ASCII-domain string
  operations (shebang/extension lowercasing, JSON `\uXXXX` hex parsing) now use
  ASCII-only helpers instead of `lowercased()` / `Character.hexDigitValue`,
  which avoids linking Unicode case-folding / numeric-property tables into the
  browser wasm build. Behaviour is identical for these ASCII inputs (pinned by
  the shared `output-contract.json`). The `wasm-opt` invocation also gains
  `--converge --strip-producers`. The shipped bytes change only when the wasm is
  re-vendored (`scripts/build-runner-wasm.sh`).
