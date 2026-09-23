### Removed

- **Stray coverage file.** A 9 MB `default.profraw` that a local test run wrote into the working tree was committed to `main` by accident with #1558. It is removed, and `.gitignore` now ignores `*.profraw` so the same file cannot be committed again.
