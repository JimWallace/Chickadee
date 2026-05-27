### Fixed

- **In-browser notebook editor kernel failed with `Can't find a pure Python 3
  wheel for: 'comm'`.** `pyodide_kernel` imports `comm` at startup (its comm
  manager), but `comm` was in neither the vendored Pyodide lock nor the kernel's
  piplite index, so the notebooks editor — which eagerly initializes the comm
  manager — hit `piplite.install('comm')`, which can't reach PyPI
  (`disablePyPIFallback`) and raised. `comm` is now vendored into the canonical
  Pyodide so micropip resolves it locally. (An import-closure audit of the kernel
  confirms `comm` was the only missing dependency.)
