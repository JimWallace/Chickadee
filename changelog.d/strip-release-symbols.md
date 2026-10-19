### Changed

- **Smaller server and runner binaries, again.** The CI image build now also removes the symbol table from each release binary. The server binary goes from 171 MB to 121 MB and the runner from 80 MB to 64 MB, which makes each deploy pull about 10 MB less (compressed). The `debug-symbols-<tag>` artifact keeps the symbols, so a crash backtrace gets its function names when gdb loads that file.

### Fixed

- **Correct binary sizes for 0.5.748.** The 0.5.748 entry gave sizes that were not measured on the CI build. In CI, that change took the server binary from 301 MB to 171 MB and the runner from 98 MB to 80 MB, and each deploy pulls about 48 MB less (compressed).
