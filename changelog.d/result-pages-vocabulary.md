### Fixed

- **The CSV enrollment result page shows the rejected usernames again.** Its template read three computed properties (`rejectedCount`, `hasPreEnrolled`, `hasRejected`), and synthesized `Encodable` does not encode computed properties. So the Rejected row was empty, and the pre-enrolled note and the rejected-usernames section never showed. The template now derives them from the stored fields with the `count` tag (#1973).

### Changed

- **Three pages use the shared facts card, note and toolbar.** The CSV enrollment and bundle import result pages show their counts as a `.detail-grid` in a `.card`, with one-sentence `.section-note`s, and the import page's buttons sit in a `.toolbar`. The BrightSpace instructor page's two forms and two action rows use `.toolbar`. `PAGE_STYLE_BASELINE` drops from 397 to 351 (#1973).
