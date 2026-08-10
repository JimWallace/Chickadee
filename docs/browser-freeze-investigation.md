# The post-boot editor freeze: investigation and fix (Aug 2026)

Status: root-caused, mitigated, verified. The mitigations are
`Public/jl-cell-perf-patch.js` (runtime coalescer, which also carries the
auto-collapse rule) and a `disabledExtensions` entry for the upstream
`:scroll-output` plugin; the reusable tracer that found both is
`Tools/editor-smoke-test/freeze-trace-check.mjs`.

## Symptom

The instructor dashboard's "browser errors" card (which counts
`preflight_fail` + `watchdog_timeout` + `page_unresponsive`) started showing
daily events in the first week of August 2026 — 7 in one 24h window, 15 over
the week, after a full month of zero. Every one was a `page_unresponsive`
freeze-watchdog beacon: the student notebook page's main thread missed
heartbeats for ≥8 s while the tab was visible, then recovered. No submission
was lost (the submit funnel stayed 100%), no kernel failed to boot, and no
capability check failed — the freezes were transient UX stalls, not outages.

Telemetry shape, from `get_browser_diagnostics` samples:

- Chromium only (Chrome on Windows and macOS; none on Safari, whose editor
  runs the non-isolated service-worker path).
- Stall onset consistently ~58 s after the iframe collector's `boot_start`,
  i.e. ~50 s after `kernel_idle` — students a minute into a lab.
- Reported `stalled_ms` always just past the 8 s threshold (the beacon is
  one-shot and fires at the first 1 s check past the line, so 8.3–8.9 s is
  the expected reading regardless of true stall length).
- Concentrated on the busiest assignment of exam-prep week; one burst was a
  single machine with three lab tabs, each freezing on its own schedule.

## What was ruled out

- **The 61 s `@jupyterlab/services` polls** (`KernelSpecManager._pollSpecs`,
  `UserManager._pollUser`) fit the timing but not the cost: a forced
  `refreshSpecs()` under 3x CPU throttle blocks the main thread for ~0 ms
  (the lite server answers from memory).
- **An idle editor.** 150 s of watching an idle booted editor at 3x throttle
  produced zero long tasks ≥500 ms, zero heartbeat gaps, zero beacons. The
  page's own timers (watchdog ticks, freeze heartbeats, locked-UI interval,
  `sw_state` probe) are all sub-millisecond work.
- **A fix already shipped.** Nothing editor-facing landed between the stall
  builds (0.5.47/0.5.50) and 0.5.54.

## Root cause, measured: two per-message listeners

Re-running the trace with a realistic health-data notebook (numpy/pandas/
matplotlib imports, a 5,000-row DataFrame, a 1,000-row rendered table, two
figures, a groupby-describe) and a programmatic run-all reproduced the stall:
a 1.74 s main-thread block at 3x throttle on fast CI hardware — the ≥8 s
class on a mid-range student laptop. Peeling it produced TWO findings, both
upstream, both triggered once per IOPub output message:

1. **`CodeCell.updatePromptOverlayIcon` forces a reflow per output**
   (1.29 s of the 1.74 s stall). The upstream method
   (`@jupyterlab/cells`) reads `overlay.clientHeight` — a forced synchronous
   style+layout flush — and is connected to both `outputs.changed` and
   `outputs.stateChanged`, so it runs immediately after each output's DOM
   insertion invalidated layout. A data-lab run-all is therefore N outputs ×
   full-document reflow, with the document holding the 1,000-row table the
   reflow has to lay out. Upstream `main` still has the identical
   implementation, so a bundle upgrade cannot inherit a fix.

2. **The `:scroll-output` plugin measures `scrollHeight` per output**
   (1.37–1.48 s) — revealed by re-tracing with fix 1 applied: the stall's
   dominant frame moved to a closure in
   `@jupyter-notebook/notebook-extension`'s `scroll-output` plugin, which
   connects a per-cell handler to `outputArea.model.changed` and, on every
   output message, reads `outputArea.node.scrollHeight` — a forced reflow —
   to auto-collapse outputs taller than ~130 lines (1.3 × fontSize × 100).
   Same bug shape as finding 1, different plugin. (An earlier read of this
   trace blamed the Notebook 7 trust badge, whose `checkTrust` also runs per
   `modelContentChanged`; resolving the profile frame's exact minified column
   against the chunk shows the hot closure is scroll-output's measurer, and a
   config probe confirmed the trust badge was not the cost. The trust badge
   stays enabled.)

Legitimate output rendering (`createRenderedMimetype`) and MathJax scans are
a distant third at ~0.2–0.3 s combined. The 61 s `@jupyterlab/services`
polls, which fit the production timing, were exonerated by a forced
`refreshSpecs()` measuring ~0 ms.

Why this appeared with the 0.5/xeus era rather than before: both costs need
outputs to land in tight bursts. xeus-python executes a pandas lab
back-to-back (the env is pre-fetched), where the Pyodide-era editor spread
the same outputs across `loadPackagesFromImports` network stalls. Exam-prep
week's heavier notebooks did the rest.

## The fix, in two parts

**Part 1 — coalesce the reflow:** `Public/jl-cell-perf-patch.js`, injected
into the notebooks editor document beside the diagnostics collector
(`scripts/patch-jupyterlite-diagnostics.py`, asserted by
`scripts/verify-jupyterlite.sh`). It walks a live code cell's prototype chain
to the upstream `CodeCell` prototype and wraps `updatePromptOverlayIcon` so
any number of same-frame calls per cell run the original once, on the next
animation frame. The browser performs one layout per rendered frame anyway,
so the coalesced call's marginal cost is ~zero, and the icon still updates
within one frame of the last output.

A runtime prototype patch — not a vendored-bundle edit — because
`jlab_core.<hash>.js` is served `immutable` for a year
(`EditorAssetFastPathMiddleware`): an in-place byte patch would never reach a
returning student (the #574 stale-cache class), and renaming the bundle means
re-wiring every webpack reference. The injected script is cache-busted by its
own content hash, so it deploys like any other page asset. Fail-safe: every
step is guarded, and if the editor's widget shape ever changes, the patch
finds nothing and the editor runs exactly as unpatched.

**Part 2 — move auto-collapse to frame cadence:**
`@jupyter-notebook/notebook-extension:scroll-output` is added to
`disabledExtensions` in `jupyter-lite.json` (both the `Tools/jupyterlite/`
source and the served `Public/jupyterlite/` copy — the supported JupyterLite
mechanism, no vendored bytes touched), because its handler pays the reflow
per message and, if left running beside a replacement, would fight the class
toggle. The auto-collapse behaviour itself is NOT lost:
`jl-cell-perf-patch.js` re-applies upstream's exact rule (user-set `scrolled`
metadata wins; threshold 1.3 × fontSize × 100; the class toggles both ways;
one initial pass covers reopened notebooks with saved outputs) inside the
same per-frame callback as part 1, so the measurement rides the one layout
pass the browser was doing for that frame anyway.
`JupyterLiteConfigFlagMiddleware` edits the served list per request for
WebKit's service-worker entry and preserves unknown entries, so the new entry
survives both engines. Setting the plugin's own `autoScrollOutputs` setting to
false instead would not work: the disabled path still runs per message and
removes the scrolled class each time.

Verified two ways:

- `Tests/BrowserRunnerJSTests/cell-perf-patch.test.mjs` pins the coalescer's
  discovery, coalescing, disposal, and idempotency contracts, plus the
  auto-collapse rule's threshold and user-override semantics.
- The freeze-trace harness, run four times (see below).

## Verification runs

All runs: Chromium, 3x CPU throttle from `kernel_idle`, 150 s watch, the same
realistic notebook. "Stall" is the worst main-thread long task; "gap" is the
watchdog-style heartbeat gap (>1.2 s reported).

| configuration | worst stall | gaps | dominant frame in the stall |
|---|---|---|---|
| idle editor (no run-all), unpatched | none ≥0.5 s | none | — |
| run-all, unpatched | 1.74 s | 2.08 s | `updatePromptOverlayIcon` (1.29 s) |
| run-all, coalescer only | 2.13 s | 2.43 s | scroll-output measurer (1.37–1.48 s) |
| run-all, coalescer + scroll-output disabled | **0.56 s** | **none** | the coalesced per-frame pass itself (0.46 s) |

The residual 0.56 s frame is the bounded once-per-frame cost on a document
holding a 1,000-row table: the per-cell callbacks still interleave a read and
a write within the frame, so a burst frame pays roughly two reflows per
changed cell rather than one total. If that ever needs shrinking, the next
step is a frame-global queue that batches all reads before all writes — not
done now, because 0.56 s at laptop-equivalent throttle sits ~14x under the
8 s watchdog line.

## If it comes back

`page_unresponsive` beacons carry the page-build version; check byAppVersion
first (a stale-tab cohort looks like a regression). The tracer reproduces the
whole pipeline in one command:

```bash
cd Tools/editor-smoke-test
SMOKE_CHECK=freeze-trace-check.mjs ./run-smoke.sh
```

Knobs: `FREEZE_THROTTLE` (default 3x), `FREEZE_WATCH_MS` (default 150 s),
`FREEZE_RUN_ALL=0` to watch an idle editor, `FREEZE_STALL_MS` for the
long-task report threshold. It prints long tasks with attribution, heartbeat
gaps, any real watchdog beacons, and the dominant profile stacks inside each
stall, and saves the raw `.cpuprofile`.

Residual candidates the mitigation does not cover: genuine memory-pressure
freezes on low-RAM machines with several kernel tabs (the preflight low-memory
hint and the wasm-crash recovery own that), and any future upstream regression
of the same shape — which now has a named tracer pointed at it.
