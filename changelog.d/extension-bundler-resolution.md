### Changed

- **The JupyterLite extension resolves modules as a bundler does.** Its
  `tsconfig.json` sets `moduleResolution` to `bundler` in place of `node`, which
  TypeScript 7 removed (TS5108). This unblocks the TypeScript 7 update (#2873).
  The built extension is unchanged under TypeScript 5.5.4.
