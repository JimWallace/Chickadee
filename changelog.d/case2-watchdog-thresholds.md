### Changed

- **Editor kernel-boot watchdog thresholds raised so slow-but-healthy boots
  aren't flagged as failures (CASE 2).** The 24 h post-deploy `bootContext`
  telemetry showed the dominant `kernel_unknown` signal was the watchdog firing
  on boots that then recovered on their own (observed `unhealthy_ms` 12–37 s) —
  on every engine and device class, including a 32 GB / 16-core Chrome and modern
  Safari 26.5, so it was boot *latency*, not a hung kernel. Two thresholds bumped:
  - `SUSTAINED_UNHEALTHY_MS` 10 s → **30 s** (`jl-kernel-diagnostics.js`): the
    in-iframe collector now only beacons `kernel_unknown` once a kernel has sat
    unhealthy for 30 s, so slow boots that recover before then produce a clean
    boot funnel instead of a false `kernel_unknown`. A genuinely-stuck kernel
    still beacons (and still hits the unchanged 75 s `boot_stalled` deadline).
  - `SLOW_BOOT_NOTICE_MS` 25 s → **35 s** (`notebook.js`): the WebKit upload-
    fallback notice fired at 25 s, but boots were observed recovering as late as
    ~37 s; 35 s cuts premature notices while still surfacing the (non-blocking)
    fallback well before the hard deadline.
- This also reduces the false-failure rate in the editor exec/lifecycle CI
  probes (the same slow boots), per #1053.
