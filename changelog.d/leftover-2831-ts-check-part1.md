### Changed

- **23 more frontend scripts are type-checked.** They opt in with `// @ts-check`, and `tsc` reports no errors. The fixes are JSDoc annotations and casts only, so no served file changes behaviour. A `paths` entry in `jsconfig.json` types the `/vendor/codemirror.js` import (#2831).
