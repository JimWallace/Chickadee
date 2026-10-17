### Changed

- **The notebook shows before its kernel is ready.** The loading panel now fades when the editor has drawn the cells, not when the kernel is idle. The kernel chip shows "starting" until the kernel is ready, and a cell run before then waits for it. Measured in headless Chromium: after a workbench switch between the starter and the solution, the cells show in about 2.5 s instead of about 8.7 s; on a first load, in about 4 s instead of about 10 s.
