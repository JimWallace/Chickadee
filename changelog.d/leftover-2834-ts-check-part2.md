### Changed

- **Four larger frontend scripts are type-checked.** `app.js`, `browser-runner.js`, `support-files.js` and `notebook.js` opt in with `// @ts-check`, and `tsc` reports no errors. The fixes are JSDoc annotations and casts only, so no served file changes behaviour. Two module declarations in `types/` type the dynamic imports of the iframe bridge and the runner-core loader (#2834).
