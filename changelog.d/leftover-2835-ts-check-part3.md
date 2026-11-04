### Changed

- **The last two large frontend scripts are type-checked.** `suite-table.js` and `pattern-family-editor.js` opt in with `// @ts-check`, and only the two editor-iframe scripts stay on `scripts/ts-check-pending.txt`. The fixes are JSDoc annotations and casts only, so no served file changes behaviour (#2835).
