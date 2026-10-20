### Changed

- **Frontend JS uses the shared ChickadeeUI helpers (#2721).** `ChickadeeUI.fetchJSON` has an `errorMessage` option, so a call site keeps its own message, and more fetches use it. Page scripts read the CSRF token from `ChickadeeUI`, and the edit and new pages no longer pass it to each editor. New `ChickadeeUI.el` and `ChickadeeUI.wireOnce` helpers replace the local copies. The global and section inputs editors share `ChickadeeInputsCore.wirePanel`.

### Removed

- **The four `<lang>-eval-worker.js` files (#2721).** `Public/eval-worker.js?lang=<language>` is now the one auto-compute worker for Python, R, Lua and Octave, and `LanguageDescriptor` names it.
