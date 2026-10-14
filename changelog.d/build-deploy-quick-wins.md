### Changed

- **The Octave and R kernel libraries are compressed.** The server sent the
  kernel `.so` files as `application/octet-stream`, which no compression
  allowlist includes. A cold Octave boot downloaded about 52 MB of libraries
  uncompressed, and an R boot about 11 MB. The app now gzips them. The
  libraries compress about 4x, so an Octave boot sends about 13 MB.
- **nginx caches the kernel packages immutably.** On a systemd host,
  `deploy/nginx.conf` still set `no-cache` on every `kernel_packages/` tarball.
  That undid the one-year immutable cache that the app sets for them (#2544).
  The tarballs now get the same immutable header from nginx.

### Fixed

- **The pushed image is the image that was tested.** `docker-build.yml` built
  the image once to boot and scan it, then built it again to push it. If the
  build cache had lost a layer, production could get a digest that was never
  tested. The workflow now pushes the image that it tested. A `docker push`
  carries no buildx provenance attestation. Nothing in the deploy reads one.
- **The runner wasm re-vendors when its toolchain changes.** The source hash
  did not include the SDK pin, the root `Package.swift` or `.node-version`. A
  change to one of them did not rebuild the browser grader.
- **The wasm vendor job cannot commit an unstripped module.** In CI, the build
  now stops when `wasm-opt` is not available, and the vendor job runs the size
  check before it commits.
