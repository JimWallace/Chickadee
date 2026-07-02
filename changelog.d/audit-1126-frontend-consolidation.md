### Changed

- **Frontend JS consolidation finished (#1126).** `chickadee-ui.js` now owns
  the shared `setStatus`, `extractErrorMessage` (unifying the two divergent
  copies — one parsed JSON, one scraped the error page — that flowed through
  the same renderer ctx slot), and a `fetchJSON` wrapper that replaces the
  repeated `if (!r.ok) return r.text()…` boilerplate (×5 in suite-table.js
  alone). The two inputs editors' shared mechanics (value classification,
  literal parsing, row validation, payload build, debounced auto-save) moved
  to a new `inputs-editor-core.js`; the editors keep only their class names
  and endpoints. Dead `suite-list.js` is deleted (only its upload
  classification survived — folded into `suite-table.js`), and the pure
  helpers now have `.mjs` unit tests (`suite-table.test.mjs`,
  `inputs-editor-core.test.mjs`).
