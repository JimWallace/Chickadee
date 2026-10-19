### Changed

- **Two fail-open defaults are closed (#2714).** `PatternKind.callsFunction` is now the one exhaustive answer to "does this kind call `functionName`?". The pattern validator, the renderer and the notebook anchor read it, and the handler default of `true` is gone. `LanguageDescriptor.executableOutputProbe` now holds the compile-and-exec probe program. `capabilityRequiresExecutableOutput` derives from it, so a compiled language cannot need executable output and have no probe. Behaviour does not change for the seven languages that ship.
