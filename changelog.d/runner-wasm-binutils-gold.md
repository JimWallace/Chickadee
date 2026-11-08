### Fixed

- **The browser runner's wasm re-vendor installs Swift again.** On the Ubuntu 26.04 runner, binutils no longer ships the gold linker, and `swiftly install` failed its dependency check, so the re-vendor after #2892 stopped before it built anything. The workflow now installs the separate `binutils-gold` package.
