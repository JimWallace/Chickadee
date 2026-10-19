### Changed

- **Frontend JS uses more of the shared ChickadeeUI helpers (#2721).** `ChickadeeUI.fetchJSON` has an `errorMessage` option, so a call site keeps its own message. More fetches use it, and the suite table, the script renderer and the starter-test panel read the CSRF token from `ChickadeeUI`. New `ChickadeeUI.el` and `ChickadeeUI.wireOnce` helpers. `Public/eval-worker.js` is now the one auto-compute worker for Python, R, Lua and Octave; each `<lang>-eval-worker.js` is a short entry file that loads it.
