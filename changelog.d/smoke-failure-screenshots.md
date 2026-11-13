### Changed

- **The editor smoke job keeps its failure diagnostics.** The CI `smoke` job now sets `SMOKE_SCREENSHOT_DIR` and uploads it as the `smoke-diagnostics-<engine>` artifact when a step fails. `run-smoke.sh` gives each check its own subdirectory and adds the server log on a failure. The workbench shell check also saves a full-page screenshot, an editor-frame screenshot, the browser console and a Playwright trace (#2991).
