### Added

- **A weekly check that the vendored xeus kernels are still current.**
  Dependabot watches every other dependency here, including the JupyterLite
  pip pins, but it cannot watch the kernels: its `conda` ecosystem matches only
  `environment.yml`, resolves against anaconda.org rather than
  `repo.prefix.dev`, reads versions for the wrong platform, and yields nothing
  for an unpinned dependency — and ours are unpinned on purpose. The kernels
  therefore moved with no file in the repository changing, and nothing said so.
  `scripts/check-kernel-currency.py` asks the solver that actually builds them
  (`micromamba create --dry-run`, `emscripten-wasm32`) and compares its answer
  to the tarballs vendored under `Public/jupyterlite/xeus/`, so a difference
  means exactly that a re-vendor would change the shipped bytes.
  `.github/workflows/kernel-currency.yml` runs it weekly, off the pull-request
  path so an upstream release can never block a merge. Why the check asks a
  solver instead of reading published versions is recorded in its header: the
  simpler approach reports three of the four environments as stale forever,
  because strict channel priority and transitive ABI pins both have to be
  honoured to get the answer right.
