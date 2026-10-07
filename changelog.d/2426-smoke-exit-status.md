### Fixed

- **The editor smoke fails again when a Chromium check fails.** Three steps read the exit status after an `if` block, where it is always 0, so a Chromium failure of the selftest, the notebook-page test or the workbench test passed the required gate. The steps now take the status in the `else` branch. (#2426)
