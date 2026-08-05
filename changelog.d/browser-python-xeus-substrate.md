### Added

- **Python browser grading can run on the xeus-python kernel (#1271).** A new
  substrate grades `.py` test scripts on the same `chickadee-python` environment
  the notebook editor runs, so authoring and grading become one environment for
  Python as they already are for R. Off by default: set
  `BROWSER_PYTHON_SUBSTRATE=xeus` to opt a deployment in. Pyodide remains the
  default because a fixed build-time environment narrows what a submission may
  import — see `docs/xeus-python-grading-migration-plan.md` for the scan to run
  before flipping it.

### Changed

- **The xeus kernel boot is shared between the R and Python graders**
  (`Public/xeus-kernel-shared.js`), so there is one implementation of booting a
  vendored kernel rather than one per language.
- **The browser-grading smoke probe covers both languages.**
  `Tools/r-grading-smoke` became `Tools/browser-grading-smoke` and runs R and
  Python in CI. Both languages run even when only one looks touched: they share
  the kernel boot, the vendored bootstrap and the workspace writer.
