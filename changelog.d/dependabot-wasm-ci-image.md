### Added

- **Dependabot now watches the WebAssembly package graph and the CI image.**
  Both `swift` and `docker` were configured with `directory: "/"`, which does
  not recurse, so `wasm/Package.swift` and `.github/docker/ci-image/Dockerfile`
  sat outside the config entirely. The wasm gap had already cost something
  real: JavaScriptKit 0.59.0 was needed to fix a `PackageToJS` bug that shipped
  the browser-runner artifact without its WASI shim, and it landed by hand in
  #1522 because nothing was watching. The wasm entry is deliberately ungrouped,
  for the reason the SwiftLint plugin is excluded from the Swift group: a
  JavaScriptKit bump has broken the shipped artifact once and needs its own
  reviewable PR. `docker-compose.yml` stays out on purpose — both services run
  our own image at `:latest`, so there is no version to bump.
