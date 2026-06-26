### Added

- **Editor kernel boot diagnostics now capture the *why* of a stalled/unknown
  kernel (CASE 2 instrumentation).** The in-iframe collector
  (`jl-kernel-diagnostics.js`) appends a PII-safe environment snapshot
  (`bootContext()`: `crossOriginIsolated`/`SharedArrayBuffer`,
  `navigator.deviceMemory`/`hardwareConcurrency`, service-worker control, whether
  the JupyterLite shell rendered, the captured boot-error count + last error
  source, and the furthest boot phase reached) to the `kernel_unknown` and
  `boot_stalled` watchdog beacons. Previously these carried only a bare
  `"kernel status unknown"`, localizing *where* a boot stalled but never *why*.
  Capability/device-class signals only — never student code, output, grades, or
  identity — and emitted strictly during the pre-idle boot window.
- **Transient vs. terminal kernel boots are now distinguishable.** A
  `kernel_idle` that follows a previously-reported unhealthy streak is tagged
  `recovered=1;unhealthy_ms=…`, so a slow-but-healthy boot (the watchdog crying
  wolf) can be subtracted from genuine terminal stalls — the `kernel_unknown`
  count was previously indistinguishable between the two. The `kernel_unknown`
  beacon is now also once-guarded so the varying context string can't bypass the
  dedup and emit one per poll.
