### Changed

- **One place decides cross-origin isolation per engine (#2112).** `COEPMiddleware` and `NotebookAssetIsolationMiddleware` each added `Vary: User-Agent`, returned early for WebKit, and wrote the isolation headers by hand. `Response.applyCrossOriginIsolation(for:)` does that once, and both call it. The headers a page or an editor asset receives do not change.
