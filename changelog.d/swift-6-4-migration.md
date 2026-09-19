### Changed

- **Swift 6.4 toolchain.** The package, the production image, the CI job
  images and the Embedded WebAssembly SDK all move from Swift 6.3 to 6.4.
  `Package.swift` declares tools version 6.4. The wasm SDK pin moves to the
  6.4.0 bundle, with the swiftly toolchain in `runner-wasm-vendor.yml` kept
  matched to it.
  The base images stay on Ubuntu 24.04 (noble). Ubuntu 26.04 became the new
  Docker `latest` in the same upstream release, but a distro change moves the
  seven grading interpreters at once and is held for its own change.

- **The release build pins `--build-system native`.** SwiftPM 6.4 makes the
  Swift Build engine the default, and its autolink extraction drops the
  transitive private dependency `lib_FoundationICU.a`. The product link line
  then carries `-lFoundationInternationalization` without `-l_FoundationICU`,
  and a static release link fails with about 300 undefined ICU symbols. Only
  the static release link is affected: the debug build, the full test suite
  and every lint and guard are clean on the default engine. `native` is
  deprecated and prints a warning, so remove the flag from the `Dockerfile`
  and `docker-build.yml` once the default engine links statically.

- **The runner's release build links `-lcurl` explicitly.** `chickadee-runner`
  polls the server with URLSession, so it links
  `lib_CFURLSessionInterface.a`, and Swift 6.4 drops libcurl from the static
  link line the same way it drops `lib_FoundationICU.a`. Neither static SDK
  has ever bundled curl; on 6.3 it arrived through autolink. Verified against
  a control: the same product on the same machine links clean on 6.3 and
  fails on 6.4.
