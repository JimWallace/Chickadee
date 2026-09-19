### Fixed

- **The browser grading wasm was 80 % debug data.** The release build links
  with `-g`, the PackageToJS plugin strips DWARF only through a `wasm-opt` it
  finds on `PATH` (CI has none, so it warned and copied the module whole), and
  `scripts/build-runner-wasm.sh` then ran its own `wasm-opt -Oz` without
  `--strip-debug`, which keeps unknown custom sections. Every re-vendor since
  the artifact existed shipped ~1.2 MB of `.debug_*` sections inside a ~1.5 MB
  module (~360 KB of the ~490 KB on the wire). The build now strips them and
  compiles the bridge with `-Osize`: the vendored artifact is ~270 KB raw /
  ~134 KB gzip with byte-identical grading output, and the size guard's
  thresholds are rebaselined so an unstripped module fails the ceiling instead
  of passing under it.
- **Footer numbers parse to the correctly rounded value.** RunnerCore's JSON
  footer parser used a hand-rolled mantissa-times-power-of-ten fold because
  `Double(String)` did not link under Embedded Swift. Each step rounded
  separately, so `"score": 0.7` parsed to `0.7000000000000001`, `"0.3"` to
  `0.30000000000000004`, `"1e308"` to `9.999999999999998e+307`, the largest
  finite double to `inf` and the smallest normal one to `0` — on both runners,
  since they share the code. Swift 6.4 reimplemented string-to-double parsing
  for Embedded Swift, so the parser is `Double(String)` again, on both runners,
  pinned exactly by `JSONFooterNumberExactnessTests`.

### Added

- **RunnerCore is compiled as Embedded Swift on every PR.**
  `scripts/check-runnercore-embedded.sh` (in `format-lint`, with a guard
  fixture) compiles the module with `-enable-experimental-feature Embedded` on
  the host toolchain in about seven seconds and needs no wasm SDK. Until now the
  only Embedded compile ran in the `runner-wasm-vendor` job on `main`, after
  merge, so a `Mirror` or a `String.contains(String)` in RunnerCore was green
  everywhere and broke the browser artifact's rebuild.

### Changed

- **The wasm bridge's BridgeJS note is corrected.** `wasm/Package.swift` and
  the bridge said BridgeJS was incompatible with Embedded Swift. On
  JavaScriptKit 0.59 with the Swift 6.4 Embedded SDK a `@JS` export compiles,
  runs, and costs nothing once it replaces the dynamic bridge; the migration is
  scoped as a follow-up in `docs/runner-wasm-swift-6-4-review.md`.
