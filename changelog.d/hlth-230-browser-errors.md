### Fixed

- **The benign JupyterLab `insertWidget` boot rejection is no longer reported as a `kernel_error`.** The boot-time layout race (`this.layout.insertWidget` on a still-null layout) rejected on essentially every editor load in every engine and never affected the boot — a full month of production telemetry shows ~1 such rejection per successful `editor_ready`, making it 96% of all `kernel_error` rows and burying real failures (`kernel_unknown`, `boot_stalled`). The in-iframe collector now drops it at the source, matched on the property name so both the Chromium and WebKit phrasings are covered.

### Changed

- **Safari is no longer version-warned by the supported-browser matrix.** The D2L-seeded floor (Safari 26 — Apple's year-numbering jumped 18 → 26 in 2025) flagged a large working population: Safari tracks the OS, so 16–18 remain common, and production telemetry on the xeus editor shows Safari 17.3–18.6 booting and grading fine on the deliberate WebKit service-worker path while generating every `below_matrix` beacon. Safari/WebKit (desktop and iOS) is now floorless in `SupportedBrowserMatrix`; a WebKit that genuinely cannot run the editor is still caught by the runtime capability probe, the slow-boot notice, and the server-side grading failover. Chrome/Edge/Firefox floors are unchanged, and the banner copy no longer names a Safari version.
