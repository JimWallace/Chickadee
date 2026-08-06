### Changed

- **Browser-graded Python boots a bare kernel and installs packages when a
  script asks for one.** The Python environment is 61 MB across 48 packages, and
  **84% of it is the optional data-science half** — most of which a given
  assignment never touches. `python-grading-worker.js` now boots only the
  closure of `xeus-python` (the interpreter and the kernel), and when a script
  fails with `ModuleNotFoundError: No module named 'X'` it resolves X to its
  owning conda package, installs that package's closure into the **live**
  kernel, and re-runs that one script.

  Measured in Chromium, 3 runs, from local disk — so these are *install* costs
  (untar, FS write, `dlopen`), not download, which means the saving survives a
  fully warm cache and is larger over a real network:

  | boot | packages | payload | median |
  |---|---|---|---|
  | full env | 48/48 | 61 MB | 8604 ms |
  | bare kernel | 28/48 | 9.7 MB | 4822 ms |
  | + numpy | 29/48 | 13 MB | 4839 ms |
  | + matplotlib | 44/48 | 35 MB | 6092 ms |

  Adding to a running kernel costs 242 ms (numpy) or 696 ms (pandas). `scipy`
  alone drags in 16 MB of `openblas` — which `numpy` does not need — for an
  import that takes 0.09 s.

  Failure-driven rather than predicted, deliberately: under browser grading the
  test script imports the *student's* module, so the student's imports run too
  and the server cannot know them. Predicting the set means being wrong for the
  one student who imported something the tests did not; the kernel cannot be
  wrong about what is missing. The loop is bounded — each pass must install at
  least one new package — and a module the environment does not have leaves the
  original `ModuleNotFoundError` exactly as it was.

  R is unchanged: its optional half is only 36% of the payload, and `r-base`
  plus `r-stringi` are 39 MB of unavoidable kernel.

### Fixed

- **Kernel package requests no longer cost a database lookup each.** The
  `kernel_packages/` subtrees are now on `EditorAssetFastPathMiddleware`, so the
  ~50 package fetches a boot makes no longer ride the full middleware chain and
  pay a Fluent session lookup they never needed.

  Scoped to `kernel_packages/` rather than `/jupyterlite/xeus/` wholesale, which
  is the version that shipped and was reverted in v0.5.19: the wider prefix also
  captures `kernels.json` and each `<env>/<kernel>/kernel.json`, which the editor
  fetches during app **startup**, before any kernel exists.
  `kernelStartupJSONStaysOnTheNormalChain` asserts both directions so a
  well-meaning prefix widening fails in CI rather than in front of a student.

- **Installing into a live kernel had to happen from the environment prefix.**
  By the time a script triggers an on-demand install the kernel has `chdir`'d
  into the student workspace, and the vendored unpacker resolves paths relative
  to the working directory — installing from there fails inside the bundle with
  a bare `Error` carrying no message. `addPackages` chdirs to `/` and restores
  afterwards. Invisible to every unit test; only a real kernel shows it, and
  `Tools/browser-grading-smoke` is what caught it.

### Added

- **`importable-modules.json` records which package ships each module.**
  `moduleOwners` is a by-product of the scan `derive-kernel-modules.py` already
  performs — the tarball being read *is* the answer — so it cannot drift from the
  shipped bytes, and there is no distribution-name-to-import-name table to
  maintain and get wrong (`PIL` → `pillow`, `matplotlib` → `matplotlib-base`).

- **The browser grading smoke proves on-demand loading on a real kernel.** One
  test imports a package absent at boot and asserts it computes; another imports
  a module the environment does not have and asserts it still fails the ordinary
  way, which is what shows the retry terminates rather than spinning.

- [docs/kernel-boot-cost.md](../docs/kernel-boot-cost.md) — what a kernel boot
  costs, measured per package and per environment; why cross-user caching is not
  available; and why the editor is deliberately not in this slice.
