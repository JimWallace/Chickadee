### Added

- **Kernel-boot timing in the in-browser editor diagnostics.** The in-iframe
  collector now stamps `elapsed_ms` (since `boot_start`) on the `app_ready`,
  `kernel_starting`, and `kernel_idle` phases, so the browser-diagnostics
  funnel carries a phase-localized boot-time breakdown (shell vs. kernel) and a
  boot-time distribution — making it possible to tell a one-off slow boot from a
  fat tail, and to localize where a slow boot spends its time. No new event
  kinds; the parent bridge already forwards a `kernel_phase` message.
