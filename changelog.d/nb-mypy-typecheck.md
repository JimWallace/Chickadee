### Added

- **Type-checking in the in-browser notebook editor (nb_mypy), on by default.**
  Every cell is now type-checked by mypy as it runs, surfacing type warnings
  inline — no setup cell, across every assignment. Built on the unified
  canonical Pyodide: `nb_mypy` (+ `astor`) are vendored into the one
  `Public/pyodide` lock via a declarative extras manifest
  (`Tools/vendor/pyodide-extra-packages.json`), preloaded through
  `loadPyodideOptions`, and activated at kernel startup
  (`%load_ext nb_mypy; %nb_mypy On`). Activation is **fail-safe**: if nb_mypy
  is ever unavailable or incompatible, the kernel still starts and type-checking
  is simply absent — it can never block the editor. nb_mypy 1.0.6 targets
  IPython 9 / mypy 1.x / Python ≥3.11, matching the Pyodide 0.29.3 runtime.
