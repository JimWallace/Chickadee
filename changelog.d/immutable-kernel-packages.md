### Changed

- **Kernel packages are cached immutably.** The tarball that the build rewrites (`pyodide-http`) now carries its content hash in its name, so every name in a vendored `kernel_packages/` tree maps to one set of bytes. The server now serves those tarballs as immutable, so a warm kernel boot asks for no package, where it sent about 50 conditional requests before. For 150 students who join a lecture activity at once, that is about 7,500 fewer requests. `check-xeus-vendored.sh` asserts the naming. See `docs/kernel-boot-cost.md` §"Caching".
