### Changed

- **Editor exec-probe now classifies the upstream WebKit WASM crash separately
  from a real deadlock.** The `editor-exec-probe` diagnostic (WebKit leg) was
  intermittently red on a fatal Safari WASM crash — `RuntimeError: Out of bounds
  memory access (evaluating '__pyproxy_apply')` — which is an upstream WebKit
  engine bug ([WebKit #286266](https://bugs.webkit.org/show_bug.cgi?id=286266)),
  not a Chickadee regression and not fixable in our JS. The probe now (1)
  relaunches a **fresh browser per iteration** so a single WebKit process can't
  accumulate WASM/TextDecoder state across back-to-back kernel boots and inflate
  the crash rate above a real one-kernel-per-session student, and (2) tags a hang
  caused by the WebKit crash as `webkitWasmCrash` and reports it without failing
  the leg — only a genuine our-code post-idle `exec_hang` deadlock fails the
  probe. Production telemetry corroborates that real Safari students rarely hit
  the crash (the editor kernel-boot funnel is ~92% healthy on Safari/macOS).
