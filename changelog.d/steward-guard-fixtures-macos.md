### Fixed

- **Guard fixtures run on macOS.** Nineteen guard fixtures called GNU-style `sed` in-place edits, which BSD `sed` on macOS refuses, so `scripts/check-guards.sh` failed on macOS (and one fixture left a stray backup file) while CI on Linux stayed green. `check-guards.sh` now defines `sed_inplace`, which writes to a temporary file and copies the result back, and every fixture uses it with the same defect. The new `scripts/check-fixture-portable-sed.sh` guard, with its own fixture, fails when a fixture calls `sed` in place directly.
