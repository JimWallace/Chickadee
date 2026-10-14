### Changed

- **The kernel packages no longer carry build-only files.** A kernel unpacks
  every package into browser memory at boot. A new build step,
  `scripts/prune-kernel-packages.py`, removes static `.a` archives, headers,
  manuals, CPython's test suite and the second copy of each kernel shared
  library, which the loader fetches from the kernel directory. Unpacked, an
  Octave boot loads about 152 MB less, Lua 50 MB, Python 48 MB and R 13 MB.
  Each changed archive gets a content-hash name, so the immutable cache stays
  correct. `check-xeus-vendored.sh` fails if a package still holds such a file.
