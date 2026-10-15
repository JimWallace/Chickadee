### Changed

- **The docs list the Octave functions that the browser kernel lacks.** The emscripten-forge Octave build has no FFTW, ARPACK, SuiteSparse, Qhull, GLPK, SUNDIALS, zlib, HDF5 or libsndfile. So `fft`, `eigs`, sparse `chol`, `convhulln`, `glpk`, `ode15s`, `gzip` and others fail in the browser, while instructor validation passes on the native worker. `docs/authoring-parity.md` has the measured list.
