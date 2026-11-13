### Fixed

- **No wardrobe item without its toast during a retest.** The result page grants a wardrobe item only when the submission does not await a result. It now uses `SubmissionStatus.awaitsResult`, the same test as the page, so a `.running` retest no longer grants an item that never shows a toast (#3018 review).

### Changed

- **Admin course page state words.** The assignment state badge reads "open", "staff only" and "closed" in lower case, as the dashboard does. Before #3018 it read "Open", "Preview" and "Closed". The three badge branches are now one span.
- **One result-page URL.** The result page and its state poll response build the "View results" link from one helper. The docs say that the poller skip of identical markup is best-effort, and that `.due-relative` modifies `DueDate`.
