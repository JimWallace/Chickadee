### Fixed

- **The runner wasm build no longer depends on the build folder.** swiftc
  wrote a hash of each object's LLVM IR, debug info and build paths included,
  into a 816-byte `.swift_modhash` data segment. So the same sources built in
  two folders gave different bytes and a new content-hash name.
  `build-runner-wasm.sh` now passes `-disable-incremental-llvm-codegen`, and
  two builds in different folders give identical bytes.
