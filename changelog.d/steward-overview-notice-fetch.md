### Fixed

- **The Overview shows the Create & Validate and Save & Validate notice again.** The form posts with `fetch`, and the background GET that follows the redirect took the one-shot notice before the page loaded. Now only a page navigation (`Sec-Fetch-Dest: document`, or no header) reads it.
