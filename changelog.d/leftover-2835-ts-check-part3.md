### Changed

- **Every first-party frontend script is type-checked.** `suite-table.js` and `pattern-family-editor.js` opt in with `// @ts-check`, and `scripts/ts-check-pending.txt` now lists no files. The fixes are JSDoc annotations and casts only, so no served file changes behaviour (#2835).
