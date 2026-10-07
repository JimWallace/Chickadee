### Fixed

- **A change to a bundle patch script now runs the kernel re-vendor check.** `build-jupyterlite.sh` runs the four `scripts/patch-*.py` scripts, but the re-vendor workflow did not list them, so a pull request that changed one did not prove that the bundle still builds. (#2437)
