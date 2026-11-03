### Fixed

- **CI: the changed-paths gates no longer time out on checkout.** The Browser
  probes, browser grading smoke and CodeQL jobs checked out the full history
  (`fetch-depth: 0`) before they asked which paths a pull request changed. On
  this repository that fetch could run past the 10-minute job limit, and the
  cancelled job failed the required gate before any probe ran. The jobs now
  check out at depth 1, and the `changed-paths` action fetches the base
  commit by itself, also at depth 1.
