### Added

- **Kernel cold-load measurement.** Each editor boot, browser grading boot and dashboard cache warm now sends one `asset_load` breadcrumb: whether any kernel file came over the network, the bytes fetched versus read from the browser cache, and the boot time. `get_browser_diagnostics` reports them per source and per day (`assetLoads`, `assetLoadsByDay`). See `docs/jupyterlite.md`, "What a kernel boot downloads".
- **The student dashboard warms the kernel cache before class.** When it lists an open notebook assignment, it fetches that kernel's files at idle time and low priority, once per kernel version per browser, and not on a data-saving or 2G connection, so a class's first session does not download every student's kernel at once.

### Changed

- **The design for loading only an assignment's packages in the editor is recorded, not shipped.** Grading already boots a bare kernel and adds packages on demand; the editor still loads the whole environment. `docs/kernel-boot-cost.md` §"The editor" has the measured savings and the reason it needs a change to the vendored kernel path first.
