### Fixed

- **Hardened the in-browser notebook editor against intermittent dead-kernel
  ("Kernel Unknown") boots.** A small, steady fraction of students hit a
  JupyterLite/Pyodide kernel that registered `dead`/`unknown` at startup — a
  load-ordering race, not a content bug. Three layers address it:
  - **Boot gating (root cause).** The editor iframe no longer boots eagerly from
    the template `src`. JupyterLite now starts only after the capability
    preflight resolves (`mountEditor` sets the src), so the kernel's cold boot
    no longer races the preflight's concurrent service-worker registration and
    IndexedDB probes — the same subsystems kernel startup depends on.
  - **Submit guard.** Browser grading runs its own Pyodide, separate from the
    editor kernel; the submit path now waits for the editor shell before
    starting it, so a submit clicked during a cold boot can't spin up a second
    Pyodide and starve the still-booting kernel. The wait is bounded, so a
    genuinely dead editor still degrades to grading.
  - **Recovery reload (safety net).** If the kernel still registers
    `dead`/`unknown`, the watchdog reloads the editor once before falling back
    to the upload panel, preserving the student's saved work (workspace restore
    + the existing reseed-preservation logic). A failure that persists after the
    reload is reported with the same `watchdog_timeout` / `kernel-unhealthy`
    classification, annotated `persisted after auto-reload` so the admin
    browser-diagnostics breakdown can distinguish it from a recoverable
    first-try failure.
