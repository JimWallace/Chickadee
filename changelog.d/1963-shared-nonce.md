### Changed

- **One nonce and one status-line parser for the grading workers.** `makeNonce` was copied into each of the four language grading modules, and the Lua and Octave `parseRunOutput` functions were identical. Both now live in `Public/grading-shared.js`, which every worker and the notebook page already load first, and the language modules delegate to them (#1963).
