### Changed

- **One Python string escape, in RunnerCore (#2130).** `CStyleStringEscaping` moves from Core to RunnerCore, with its numeric escapes rendered by hand instead of `String(format:)`, so the notebook extractor's `pythonStringLiteral` can call the Python preset instead of carrying a second copy of the same rule. Core gets 112 lines smaller. The output bytes do not change.
