### Fixed

- **In-browser notebook editor crashed at runtime with an unhandled promise
  rejection once the kernel booted.** The vendored Pyodide `mypy` package
  declares no dependencies, so neither `typing_extensions` nor `mypy_extensions`
  (both required by `mypy` at runtime) were loaded. When nb_mypy ran mypy on a
  cell it raised `ModuleNotFoundError`, surfacing as a kernel error. `mypy_extensions`
  is now vendored as an extra and `nb_mypy` depends on `typing-extensions` +
  `mypy-extensions` so they load with it. Verified end-to-end: the editor kernel
  now type-checks cells inline (e.g. "Incompatible types in assignment") instead
  of failing.
