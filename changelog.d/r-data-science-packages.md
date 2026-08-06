### Added

- **The R editor and grading environment now ships the tidyverse core.**
  `dplyr`, `tidyr`, `readr`, `stringr`, `tibble`, `purrr` and `forcats` are
  available in R notebooks and in browser-graded R tests. The environment was
  previously bare `xeus-r` — base R and nothing else — so any `library(dplyr)`
  failed, and failed at *grade* time, because instructor validation runs on the
  native worker's full R installation where it works fine.

- **Saving a browser-graded R test now fails if the kernel cannot satisfy its
  `library()` calls**, the R half of the Python import check added in v0.5.18.
  It reads `library(pkg)`, `require(pkg)` and `pkg::fn`, and is checked against
  what the vendored kernel actually contains. `pkg::fn` counts anywhere in the
  file while `library()` counts only at the top level: `::` is not a conditional
  construct and appears overwhelmingly inside functions, whereas an attach inside
  a function or an `if` is indented and therefore guarded.

- **A browser probe asserts every package the R environment declares actually
  attaches in a real kernel**, matching the equivalent Python check. Presence in
  the vendored tarballs is not the same as loading — the Python side learned that
  the expensive way when a transitive `urllib3` stopped the kernel booting.

### Changed

- **`ggplot2` and `lubridate` are deliberately NOT in the default R
  environment.** Both solve and install fine; both are excluded on measured cost.
  `library(ggplot2)` takes **193 seconds** on first attach in the wasm kernel and
  `library(lubridate)` 32 — against a default per-test limit of 10 seconds, and a
  student's first editor cell would simply hang. A course that wants them can add
  them to `Tools/jupyterlite/environment-r.yml` and raise its time limits; that
  is now a deliberate, documented choice rather than an accident.

  Worth knowing before adding anything else, to either environment: a kernel env
  has two costs and they fall on different people. *Boot* — fetching and mounting
  the whole env — is paid by everyone on every notebook open and every
  browser-graded submission. *Import* is paid only by a script that uses the
  package, but against the 10-second default per-test limit. Neither is free and
  the second is not proportional to size: the R tidyverse shares a dependency
  graph, so whichever package attaches first pays for all of it (~26s cold, ~58s
  for the set).

  Both environment files now carry their measured numbers, including Python's,
  which had none. `scikit-learn` costs 10.8s to import and `pandas` 4.8s, so
  scikit-learn already exceeds the default per-test limit — worth knowing for
  anyone writing a browser-graded test that uses it.
  `Tools/browser-grading-smoke` prints per-package timings; measure there rather
  than guessing from package counts.

- **`scikit-learn` and `sympy` are dropped from the Python environment.** Both
  were added during the xeus-python migration to preserve parity with what
  Pyodide *could* resolve at run time, not because any lab used them, and both
  are expensive: scikit-learn takes 10.8s to import — over the default per-test
  limit on its own — and sympy 5.9s. The environment goes from 62 packages /
  85 MB to 48 / 75 MB, and loses `requests` → `urllib3` with them, which is the
  dependency whose emscripten module has to be patched or the kernel does not
  boot at all. That patch and its guard stay in place: they cost nothing when the
  package is absent, and a future addition could bring it back.

  `numpy`, `pandas`, `matplotlib`, `scipy`, `statsmodels` and `pillow` remain.
  Note for anyone trimming further: `openblas` is 16 MB, the largest single
  package in the environment, and **only scipy needs it** — numpy does not. scipy
  plus openblas is ~27 MB of a ~69 MB payload for a package whose import is
  nearly free, and statsmodels is the only remaining reason scipy is there. That
  is the biggest boot saving still available, and it is a course decision rather
  than an engineering one.
