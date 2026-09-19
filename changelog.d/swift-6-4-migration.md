### Changed

- **Swift 6.4 toolchain.** The package, the production image, the CI job
  images and the Embedded WebAssembly SDK all move from Swift 6.3 to 6.4.
  `Package.swift` declares tools version 6.4, and SwiftPM 6.4 builds with the
  Swift Build engine by default; the package needs no change to compile clean
  under it. The wasm SDK pin moves to the 6.4.0 bundle, with the swiftly
  toolchain in `runner-wasm-vendor.yml` kept matched to it.
  The base images stay on Ubuntu 24.04 (noble). Ubuntu 26.04 became the new
  Docker `latest` in the same upstream release, but a distro change moves the
  seven grading interpreters at once and is held for its own change.
