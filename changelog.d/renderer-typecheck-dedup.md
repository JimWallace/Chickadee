### Changed

- **Type-check expression rendering deduplicated (#497).** The
  byte-for-byte duplicate type-name → check-expression mappings in the
  pattern-family `.returnTypeCheck` renderer and the notebook-check
  `.variableExists` renderer are now one shared
  `pythonTypeCheckExpression(typeName:valueExpr:)` helper in
  `PythonScriptHelpers.swift`, alongside the helpers extracted in
  v0.4.170. Generated script bytes are unchanged, so `spec_hash` and
  `TestSetupCache` keys are stable. This was the last tracked item on
  #497.
