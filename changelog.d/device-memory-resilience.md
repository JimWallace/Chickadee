### Added

- **Device-memory resilience for the in-browser notebook editor.** Two
  complementary safeguards for low-memory / Safari devices, where the Pyodide
  kernel can exhaust WebAssembly memory:
  - **Proactive warning** — on a low-RAM device (`navigator.deviceMemory` ≤ 2 GB,
    where the browser exposes it; Chromium does, Safari/Firefox omit it for
    privacy), a non-blocking, dismissible banner suggests switching to a
    laptop/desktop. The editor still loads normally.
  - **Reactive recovery** — a fatal kernel crash (the upstream WebKit "Out of
    bounds memory access", or a genuine WASM out-of-memory abort) is now caught
    mid-session by the in-iframe collector and degrades gracefully to the
    existing `.ipynb`-upload fallback with a memory-specific message, instead of
    leaving a silently-wedged cell.
  Both paths emit a diagnostic (`device_warning` / `wasm_crash`) so the
  instructor dashboard surfaces the real low-memory-device and kernel-crash
  rates. No always-on editor behaviour changes on healthy devices.
