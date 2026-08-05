# Migration plan: Python browser grading, Pyodide → xeus-python

Companion to [xeus-python-grading-spike.md](xeus-python-grading-spike.md), which
established that this is viable and measured the cost.

> **STATUS (2026-08).** Slices 1–6 are **done and merged**: Python browser
> grading runs on xeus-python only, the Pyodide grading path is deleted, and both
> languages are covered by a real-kernel probe in CI. This document is now the
> handoff for **what is left** — §A below — plus the record of how the finished
> part works and what it cost.
>
> **Two things must happen before the merged work is correct in production**,
> and neither is code:
>
> 1. **Re-vendor the JupyterLite kernels.**
>    `Tools/jupyterlite/environment-python.yml` gained scipy, sympy,
>    scikit-learn, statsmodels and pillow, but the committed bytes under
>    `Public/jupyterlite/xeus/chickadee-python/` do NOT contain them yet.
>    Adding a name to the env file changes nothing until
>    `scripts/build-jupyterlite.sh` runs, and that needs micromamba plus network
>    to `repo.prefix.dev` — it **cannot run in CI**. Until it does, `import scipy`
>    fails at grade time even though the env file lists it.
> 2. **Confirm no live assignment imports outside the env.** Pyodide used to
>    resolve ~363 packages at run time; the kernel has what is baked in. Four
>    packages Pyodide carried have no emscripten-forge build at all and cannot be
>    added: `networkx`, `seaborn`, `plotly`, `requests` (the last is moot —
>    `connect-src 'self'` means a graded test could never use it).
>
> §A1, the authoring-time import check, has since shipped and makes (2) a
> save-time error rather than a grade-time surprise. Note that it reads the
> VENDORED bytes, so it currently (correctly) rejects `import scipy` — the
> re-vendor in (1) is what will make it start accepting them.

---

## A. What is left

### A1. Reject unsatisfiable imports at authoring time — **DONE**

Shipped. `PythonImportGuard` runs at all four hand-authored-script write sites
(web create + update, `PUT /suite`, MCP `author_script`), and rejects a
browser-graded `.py` write whose imports the kernel cannot satisfy, naming the
module, the line, and the ways forward.

Three decisions worth keeping, because each changes the answer:

**Derive from the tarballs, not `environment-python.yml`.** The env file states
an intent that is only true after a re-vendor, and a re-vendor needs micromamba
plus network to `repo.prefix.dev` — CI can never do one. The env file currently
lists scipy, sympy, scikit-learn and statsmodels; the shipped bytes contain none
of them. A check derived from intent would have accepted `import scipy` and
recreated the exact grade-time failure it exists to prevent.
`scripts/derive-kernel-modules.py` reads `kernel_packages/*.tar.gz` and records
what is actually importable; `check-xeus-vendored.sh` fails if the derived index
drifts from the env beside it.

This also dissolves the distribution-name-vs-import-name problem the sketch
flagged. The tarball says `site-packages/sklearn`, so there is nothing to map.

**Browser-graded assignments only.** A worker-graded assignment runs real
`python3` on the runner and is not constrained by the kernel's package set at
all. Applying the check there would reject working scripts.

**Every ambiguity resolves toward reporting nothing.** A missed import restores
the status quo (an `ImportError` at grade time); a false positive blocks an
instructor from saving, with no self-service fix — adding a package is a
maintainer change plus a re-vendor. So the scanner only reads column-0
statements (which makes guarded and function-local imports fall out for free,
rather than needing conditional analysis), skips relative imports and anything
inside a string or comment, and the availability check additionally accepts every
`.py` file bundled in the setup, the runner-injected modules, and student-module
names. The "must NOT report" tests are the ones to keep adding to.

Stdlib names come from the union of the env's own python tarball and the build
machine's `sys.stdlib_module_names`, which is deliberately permissive: it may
include something emscripten does not really support (`multiprocessing`), which
is a missed catch, but it can never reject a stdlib import that works.

### A2. Migrate `Public/pyodide-worker.js`

The pattern-family editor's auto-compute, and the last consumer of Pyodide that
runs student-adjacent code. Same substrate swap as the grader, and the forgiving
case: it is instructor-side, so a missing package is an authoring annoyance
rather than a grade-time failure.

### A3. Retire `Public/pyodide` (~465 MB) and its guards

Only after A2. Then delete: `Public/pyodide`, `scripts/check-pyodide-parity.sh`,
`scripts/add-pyodide-extras.py`, `Tools/vendor/pyodide-extra-packages.json`, the
unused nb_mypy/astor wheels, and the vendored `jupyterlite-pyodide-kernel`
(`pyodideUrl` in `Tools/jupyterlite/jupyter-lite.json`) — which is currently kept
deliberately as the parity anchor and the revert path for xeus-python, so it goes
last and needs the same re-vendor as everything else.

### A4. Tighten the CSP

`script-src` carries `'unsafe-eval'`. If Pyodide was the only thing needing it,
this can become `'wasm-unsafe-eval'` — a real narrowing. It also retires the
accidental dependency documented in the spike, where browser Python grading
worked *because* `data:` was absent from `script-src` and that broke Pyodide's
classic-worker detection probe.

**Do not tighten the CSP while Pyodide is still loaded anywhere.**

### A5. A non-goal, recorded so nobody tries it

Do not share the editor's booted kernel with the grader. The boot is the slow
part and the temptation is obvious, but grading needs a clean session and the
editor's namespace is whatever the student has been running.

---

## What the finished part cost, for calibration

| | |
|---|---|
| xeus-python per cell | ~5 ms, independent of statement count |
| Pyodide per cell (before) | ~0–1 ms |
| Boot, ready for a pandas lab | xeus-python 7.9 s vs Pyodide ~8.5 s (3.4 s + on-demand numpy/pandas) |
| Per test script, measured end to end | 12–73 ms |

Both R lessons were recorded in this document as things *not* to carry over, and
both held: Python's stderr is captured in-process (no calling-handler
interception), and the cell needs no one-expression squeeze.

---

## Appendix: the original plan, kept for its reasoning

### 0. The gate (now partially settled — see STATUS)

**Decide the package set. This is not an engineering question and it must not be
answered by whoever writes the code.**

The fixed `chickadee-python` env provides `numpy`, `pandas`, `matplotlib`,
`PIL`, and the standard library. The vendored Pyodide additionally resolves
~363 packages at run time, of which `scipy`, `sklearn`, `sympy`, `statsmodels`,
`networkx` and `requests` were confirmed working. After the migration, anything
not in the env is an unrecoverable `ImportError` at grade time.

Chickadee's own generated tests import nothing outside the env, and students are
already held to the env by the editor. The exposure is **hand-authored
instructor test scripts** and `.py` uploads that never passed through the editor.

Do this first:

1. Scan the live test setups for imports outside
   `{stdlib, numpy, pandas, matplotlib, PIL}`.
2. Add whatever is genuinely needed to `Tools/jupyterlite/environment-python.yml`
   and re-vendor (`scripts/build-jupyterlite.sh`, then
   `scripts/setup-vendor.sh` — order matters, see CLAUDE.md).
3. Get a human decision on anything that cannot be added.

Note that adding a package is strictly an improvement over today, because it
lands in the editor too — closing the current gap where the grader can import
things the editor cannot.

Everything below assumes this is settled.

---

## 1. What already exists and must not be rebuilt

- `Public/r-grading-worker.js` — the standalone xeus boot. Proven against
  `xpython` during the spike by swapping three values out of `kernel.json`.
- `Public/vendor/xeus-bootstrap.js` — the mambajs slice, built from
  `Tools/vendor/xeus-bootstrap-entry.mjs`.
- `RoutingExecutor` in `Public/browser-runner.js` — already dispatches per
  script and boots only the substrates an assignment needs.
- `Public/grading-shared.js` — the Python grading semantics (env config,
  per-script exec, stdout capture, exit-code derivation). **Most of this carries
  over unchanged; see §3.**
- `Tools/browser-grading-smoke/` — the pattern for a probe that boots a real kernel.

`RunnerCore` owns the suite loop and output interpretation and does not change.
If a diff touches how an exit code becomes a `TestOutcome`, something has gone
wrong.

---

## 2. Slices

Each is independently reviewable and leaves grading working.

1. **Export `bootstrapPython`.** Add it to
   `Tools/vendor/xeus-bootstrap-entry.mjs`, rebuild `Public/vendor/xeus-bootstrap.js`
   via `scripts/setup-vendor.sh`. xeus-python needs it after the empack
   bootstrap; xeus-r does not (upstream branches on `kernelSpec.name === 'xpython'`).
2. **Generalise the xeus worker.** `r-grading-worker.js` hardcodes the R kernel
   spec. Lift the spec to a parameter so one worker serves both kernels, or fork
   a `python-grading-worker.js` — prefer the former, since the boot sequence is
   identical apart from `bootstrapPython` and the shared-lib map.
3. **Port the Python grading semantics** (§3). This is the only genuinely new
   thinking.
4. **Route `.py` at the new substrate** behind a flag (§5), Pyodide still
   present.
5. **Extend the smoke probe** to grade Python scripts through the real kernel
   (§4).
6. **Flip the default**, watch a real cohort, keep the flag for one release.
7. **Retire Pyodide** (§6) — a separate change, later, once nothing loads it.

---

## 3. Porting the grading semantics — where the thinking is

The R port had to reinvent the process contract because `test_runtime.R` calls
`quit()` and reads `commandArgs()`. **Python is easier, and the reason matters:
`grading-shared.js` already captures output in-process rather than relying on the
substrate.**

`STDOUT_REDIRECT_PY` swaps `sys.stdout`/`sys.stderr` for `StringIO`, and
`runScriptPython` already catches `SystemExit` into `_br_exit_code`. All of that
is pure Python and works identically inside a kernel. So:

- **Do NOT repeat the R stderr trap.** In R we had to read stderr off the
  kernel's iopub stream because `evaluate::evaluate()`'s calling handlers
  intercept message conditions before a sink sees them. Python has no equivalent
  problem — the existing `StringIO` redirection captures everything, and you
  should keep using it rather than parsing kernel streams.
- **Do NOT repeat the one-expression rule.** It was an xeus-r property
  (~180 ms per top-level expression). xeus-python costs 5 ms per cell regardless
  of statement count. Write the wrapper for clarity.

The one thing that genuinely changes: **`runPythonAsync` returns a value;
`execute_request` does not.** Today `CAPTURE_OUTPUT_PY` evaluates to a tuple that
JS reads directly. Over the Jupyter protocol you must get it out some other way.
Two options:

- **Print it behind a per-run nonce and parse it back**, exactly as the R path
  does (`makeNonce` / `parseRunOutput` in `r-grading-shared.js`). Proven, and the
  nonce is what stops student output forging the boundary. Prefer this.
- Read it off the `execute_result` message. Fewer moving parts on paper, but
  couples you to display formatting (`repr` truncation, `ast_node_interactivity`),
  which is a worse contract than a delimiter you control.

Whichever you choose, `deriveExitCode` in `grading-shared.js` stays — it encodes
the "clean exit 0 / uncaught exception 1 / SystemExit code" mapping that matches
a `python3 script` subprocess, and the native worker depends on the same mapping.

**Per-script isolation.** `envConfigPython` already flushes `sitecustomize`,
`test_runtime`, and `student_*` from `sys.modules` between runs. That is the
Python equivalent of R's global-environment wipe and it already exists — but it
was written for a long-lived Pyodide session and should be re-checked against a
long-lived *kernel* session, which additionally carries IPython's user namespace
and `In`/`Out` history. Decide deliberately whether a test script can see the
previous script's globals; the native runner gives each test a fresh process, so
the answer should be no.

**Package preloading goes away.** `preloadPackagesForFiles` exists because
Pyodide resolves imports on demand and `loadPackagesFromImports` only scans the
one string it is handed. A fixed env needs none of it — delete it with the
Pyodide path, not before.

---

## 4. Verification — do not trust the unit tests alone

The R work produced a bug that every unit test passed: stderr was silently
dropped, so `longResult` would have been empty on exactly the outcomes a student
most needs it for. It was caught only by a probe that booted a real kernel.

Required before flipping the default:

- **Extend `Tools/browser-grading-smoke`** (or add a sibling) to grade Python scripts
  through the real kernel: a pass, a fail, an uncaught exception with a message
  that must reach stderr, and a script reading `chickadee_seed()` and
  `_ck_inputs.py`. Assert on stderr explicitly — that is the check that would
  have caught the R bug.
- **`Tests/Fixtures/output-contract.json`** already pins RunnerCore's
  interpretation against both the native build and the real vendored wasm. It
  does not exercise the substrate, but a change that makes it fail means the
  shared loop was touched, which it should not be.
- **Grade a real assignment both ways** — native worker and browser — and diff
  the `TestOutcomeCollection`. Same `passCount`, same `shortResult` strings.
- `scripts/check-pyodide-parity.sh` must keep passing until Pyodide is actually
  removed (§6).

Known trap, cost me an hour: **`page.waitForFunction(fn, arg, options)`.**
Passing options as the second argument silently makes them the `arg` and leaves
Playwright's 30 s default in force. A kernel boot plus a few scripts is close
enough to 30 s that this fails intermittently and reports an opaque timeout.

---

## 5. Rollout

An assignment is Python *or* R, so the blast radius of a bad Python substrate is
"every Python browser lab" — the entire browser-graded population. Stage it.

- Route `.py` at xeus-python behind a per-deployment flag (an `AppConfig` field,
  following the pattern in `Sources/APIServer/Configuration/`), defaulting to
  Pyodide.
- The failover already exists and is the safety net: if the substrate cannot
  initialise, `RoutingExecutor.ensureReady` throws and
  `submitBrowserNotebook` fails the submission over to the native worker. Verify
  that path works for the new substrate *deliberately* — it is what turns a bad
  deploy into "slow" rather than "wrong".
- Watch `get_browser_diagnostics` and the submit-phase breadcrumbs
  (`grading_init_start` / `grading_init_done` / `submit_failed`) for a cohort
  before flipping the default.

---

## 6. Retiring `Public/pyodide` — the actual payload win

Only after nothing loads it. Three consumers, and **`/validate` is not one of
them** — instructor validation is graded by the native worker (see the correction
in [xeus-r-kernel-spike.md](xeus-r-kernel-spike.md)):

| consumer | disposition |
|---|---|
| `Public/grading-worker.js` + the `browser-runner.js` main-thread fallback | removed by this migration |
| `Public/pyodide-worker.js` — the pattern-family editor's auto-compute | same substrate swap; instructor-side, so the package set is the forgiving case |
| the vendored `jupyterlite-pyodide-kernel` (`pyodideUrl` in `Tools/jupyterlite/jupyter-lite.json`) | kept deliberately today as the parity anchor and the revert path for xeus-python; retire it and `scripts/check-pyodide-parity.sh` together |

Removing Pyodide also removes the accidental CSP dependency documented in the
spike and commented at the top of both workers — Pyodide 3.14 refuses to load in
a classic worker and only loads today because `script-src` has no `data:`, which
blocks its detection probe. **Do not "clean up" that CSP while Pyodide is still
in use.**

---

## 7. What good looks like

- One kernel technology for authoring and grading, both languages.
- `Public/pyodide` gone (~465 MB), `check-pyodide-parity.sh` gone with it.
- No accidental CSP dependency.
- `RunnerCore` untouched — the native and browser graders still cannot drift.
- A smoke probe that boots a real Python kernel and asserts on stderr.
