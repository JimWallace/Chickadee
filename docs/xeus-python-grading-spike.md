# Spike: xeus-python as the browser grading substrate for Python

Follow-on to #1271 and to the browser-graded-R work. R shipped on the vendored
xeus-r kernel; this spike asks whether Python's browser grading should follow,
which is what would let the ~465 MB `Public/pyodide` go.

**Date:** 2026-08. **Verdict: viable, and the two objections that blocked it are
both weaker than recorded — but it is gated on one build-time decision that is a
policy call, not an engineering one.**

All numbers below were measured in one sitting, in the same headless Chromium,
in the same container, against the vendored bytes — so Pyodide and xeus-python
are directly comparable to each other. They are not comparable to numbers taken
on other hardware.

---

## 1. The boot sequence is language-agnostic

`Public/r-grading-worker.js`'s boot was re-run against `chickadee-python` by
swapping three values out of `kernel.json` — env name, kernel name, and the
`metadata.shared` map — and it booted `xpython` first try.

One difference, and it is upstream's, not ours: xeus-python additionally needs
`bootstrapPython({ prefix, pythonVersion, Module })` after the empack bootstrap,
which xeus-r does not (upstream's `initializeInterpreter` branches on
`kernelSpec.name === 'xpython'` for exactly this). `Public/vendor/xeus-bootstrap.js`
would need to export `bootstrapPython` — a one-line change to
`Tools/vendor/xeus-bootstrap-entry.mjs`.

Nothing else differed. `RoutingExecutor` already dispatches per script, so the
integration is: add a Python spec, point the routing at it, delete the Pyodide
branch.

## 2. Execution speed: xeus-python is fine, and R's slowness does not generalise

The headline worry from the R work was the ~180 ms-per-top-level-expression
yield. **It does not exist in xeus-python.** It is an xeus-*r* property, not an
xeus-lite one.

Warm, best of five:

| cell | Pyodide 3.14.2 | xeus-python 3.13.1 | xeus-r 4.5.3 |
|---|---|---|---|
| 1 statement (floor) | 0 ms | 5 ms | 715 ms |
| 5 statements | 0 ms | 5 ms | 1466 ms |
| 20 statements | 1 ms | 5 ms | 4065 ms |
| `sum(range(1e6))` | 66 ms | 84 ms | — |
| `sum(range(1e7))` | 682 ms | 809 ms | — |

xeus-python has no per-statement cost at all (5 ms for 1 statement and for 20),
and compute scales linearly — the signature of a runtime doing work, not
waiting. Python's own clock agrees: 0.0 ms elapsed both across nested statements
and across bare top-level ones, where R reported ~228 ms for the bare case.

Against Pyodide, xeus-python costs ~5 ms more per script and ~20 % more on raw
compute. Over a 20-test suite that is ~100 ms. Irrelevant.

**Why R differs is worth knowing if R grading latency ever matters:** xeus-r
evaluates a cell one top-level expression at a time through R's `evaluate`
package and yields to the JS event loop between them. Python's kernel compiles
and runs a whole cell in one go.

## 3. Boot cost: xeus-python is competitive once packages are counted

| | time |
|---|---|
| Pyodide, bare | 3417 ms |
| Pyodide + first `import numpy` | +1365 ms |
| Pyodide + first `import pandas` | +3741 ms |
| **Pyodide, ready for a pandas lab** | **~8.5 s** |
| **xeus-python (numpy + pandas + matplotlib already in the env)** | **7874 ms** |

Pyodide's low bare-boot number is misleading for grading: it fetches packages on
first import, and a data-science lab imports pandas in its first test. xeus-python
front-loads the same cost into the env fetch. For the labs Chickadee actually
runs, they are a wash — with xeus-python slightly ahead.

## 4. The package set: the real gate, and it is a policy call

This is the objection #1271 correctly identifies as the sharpest. It is real,
and it is now measured rather than assumed.

What the fixed `chickadee-python` env provides: `numpy`, `pandas`,
`matplotlib`, `PIL`, and the standard library.

What the vendored Pyodide can additionally resolve **at run time**, offline, from
its 363-package index — every one of these succeeded:

| package | Pyodide resolves in | in the xpython env? |
|---|---|---|
| `scipy` | 3107 ms | no |
| `sklearn` | 5919 ms | no |
| `sympy` | 4299 ms | no |
| `statsmodels` | 1679 ms | no |
| `networkx` | 3474 ms | no |
| `requests` | 1118 ms | no |

So the gap is genuine: migrating narrows what a test script or submission may
import, from "363 packages, resolved on demand" to "whatever is baked in".

**Three things make it much smaller than that framing suggests:**

1. **Chickadee's own generated tests are already covered.** Every import emitted
   by the pattern-family and notebook-check renderers is stdlib, `numpy`,
   `pandas`, or `matplotlib`. The machine-generated bulk of the test corpus needs
   nothing added.
2. **Students are already constrained by the editor.** A browser-graded notebook
   is authored in JupyterLite, which runs xeus-python with *this same env* and no
   piplite escape hatch. A student importing `scipy` fails while they are
   working, not at grade time. The "student imports something unanticipated"
   scenario the issue worries about cannot reach submission for the notebook
   path.
3. **The remedy is a build-time list.** Anything genuinely needed goes in
   `Tools/jupyterlite/environment-python.yml` and is then available to the editor
   *and* the grader — which is strictly better than today, where the grader can
   resolve packages the editor cannot.

**What is left, and why it is a policy call:** hand-authored instructor test
scripts, and `.py` uploads that never passed through the editor, may import
outside the set. Those break on migration and the failure is an unrecoverable
`ImportError`. Deciding is a matter of scanning the existing test setups for
imports outside the env and either adding them or accepting the break — a
question about actual course content, answerable by the person who owns it.

## 5. Unrelated finding: browser Python grading depends on the CSP, by accident

Worth recording because nothing documents it and it is a live trap.

`Public/grading-worker.js` and `Public/pyodide-worker.js` are **classic** workers
that `importScripts('/pyodide/pyodide.js')`. Pyodide 3.14 refuses to load in a
classic worker — `throw new Error("Classic web workers are not supported")`.

It detects one by probing:

```js
function isClassicWorker() {
  try { globalThis.importScripts("data:text/javascript,"); return true }
  catch { return false }
}
```

Chickadee's CSP is `script-src 'self' 'unsafe-eval' 'unsafe-inline' blob:` — no
`data:`. The probe is therefore **blocked by policy**, throws, and reports
*false*. Pyodide concludes it is not in a classic worker and loads normally.

Measured both ways in this spike: serving the same worker with no CSP throws
"Classic web workers are not supported"; adding the production `script-src` makes
it load.

So browser Python grading works today because a security header defeats a feature
probe. Adding `data:` to `script-src` — an innocuous-looking change — would break
every browser-graded Python submission, which would then fail over to the native
worker: correct results, silently and much slower, with nothing pointing at the
CSP as the cause.

Migrating to xeus-python removes this entirely: the xeus boot `importScripts` a
same-origin file and has no such probe. That is a real, if unglamorous, argument
for the migration.

Until then the dependency is called out in a comment at the top of both workers.

## Recommendation

Migrating Python browser grading to xeus-python is a small piece of work on a
proven path, is performance-neutral to slightly positive, restores one
authoring/grading environment, and removes the CSP trap above.

The gating question is not technical. It is: **which packages must the fixed env
carry?** Answer it by scanning the existing test setups for imports outside
`{stdlib, numpy, pandas, matplotlib, PIL}`, then either add them to
`environment-python.yml` or accept the break.

Retiring `Public/pyodide` needs two further consumers moved, and neither is
`/validate` (see the correction in
[xeus-r-kernel-spike.md](xeus-r-kernel-spike.md)):

- `Public/pyodide-worker.js` — the pattern-family editor's auto-compute. Same
  substrate swap; instructor-side, so the package set is the forgiving case.
- the vendored `jupyterlite-pyodide-kernel`, which currently anchors
  `scripts/check-pyodide-parity.sh` and is the revert path for xeus-python. That
  guard would be retired with it.
