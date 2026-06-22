### Fixed

- **Notebook editor: stop the new kernel-boot watchdog from false-alarming on
  healthy kernels.** The v0.4.500 `kernel-boot-timeout` beacon fired on mere
  *absence* of a positive kernel-ready signal, but the parent page often cannot
  read the kernel's state inside the cross-process editor iframe — so it
  false-positived on healthy Chrome **and** Safari kernels (a spurious "kernel
  taking unusually long" message plus phantom kernel errors on the dashboard).
  The watchdog deadline now stops watching silently instead of beaconing;
  genuine no-`SharedArrayBuffer` hangs are still pre-empted up front by the
  cross-origin-isolation compat switch. The `sw_state` beacon now also reports
  `waitasync`, so the at-risk `coi=true; waitasync=false` cohort is visible
  without any iframe probing.
