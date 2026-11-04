### Fixed

- **A failed CI agent now says why.** Since 2026-10-20 every Claude agent workflow failed before the model ran, and the log said only that no structured output came back. The checks stayed green, so nobody saw it for two weeks. The shared agent action now prints the API's own error and adds it as a warning on the run. It prints the error text only when no model ran, never the model's text.
- **The weekly digest reads the ZAP run, not the ZAP issue's date.** The scan edits its issue only when the findings change, so the digest reported a missing scan in a week when the scan ran and passed.
