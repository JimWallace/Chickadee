### Changed

- **The notebook page's notices use the shared components.** The browser and low-memory notices are now `.flash-warning` banners with a "Dismiss" action button, and each is one sentence. The "Editor didn't load" panel and the small-screen notice use `.standin-panel`. The panel now sits above the editor, so the slow-boot notice that reuses it is in view. The page no longer styles `js-` hooks, and the "Save to assignment" button has `type="button"`. `PAGE_STYLE_BASELINE` drops from 427 to 397 (#1976).
