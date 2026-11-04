### Changed

- **The frontend type check runs on TypeScript 7.** TypeScript 7 refuses a bare `resolve()` on an untyped `Promise`, so the IndexedDB probe in `Public/notebook-preflight.js` now declares its promise as `Promise<void>`. Nothing changes at run time.
