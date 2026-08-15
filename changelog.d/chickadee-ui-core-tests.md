### Added

- **The frontend's core utilities have unit tests.** `chickadee-ui.js` loads on
  every page and had the least coverage relative to its reach. 17 tests now pin
  the pieces the rest of the frontend is built on: `escapeHtml`/`escapeAttr`
  (all five characters, ampersand-first, null → `""` rather than `"null"`), the
  CSRF token's meta-then-hidden-field fallback, `extractErrorMessage` (JSON
  `reason`/`error`/`message` order, the Leaf error-page scrape, and its two
  safety rules — tags stripped to a **fixpoint** so a nested fragment cannot
  survive one pass, and entities decoded with `&amp;` **last** so `&amp;lt;`
  becomes `&lt;` and never `<`), and `fetchJSON` (header and body encoding, an
  explicit token overriding the page's, 204 → null, a non-JSON success → null,
  and a failure rejecting with the *server's* message rather than a bare
  status).

### Changed

- **`runInlineScripts` has the written contract it never had.** It is the one
  place in the frontend that deliberately turns markup back into running code,
  so the boundary is now stated in the source: `root` must be a fragment the
  server rendered for this same-origin page, `[src]` scripts are excluded
  because a swap re-runs page wiring rather than re-fetching modules, and a
  non-`text/javascript` type is data (the JSON seed islands) and is left
  untouched. It stays internal on purpose — `swapHalf` is the only caller and
  the only context where the first rule can be guaranteed, and exporting it
  would make that guarantee someone else's to keep.

  Its *behaviour* is still uncovered: reaching it needs a `swapHalf` harness
  (DOMParser, `importNode`, the keepElement identity rule), which is a slice of
  its own rather than something to fake by widening the API for a test.
