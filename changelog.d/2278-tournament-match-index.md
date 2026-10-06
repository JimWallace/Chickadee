### Fixed

- **Tournament match jobs no longer scan every tournament slot.** The claim and the result ingest of a match job look up its slot by `match_submission_id`, and that column had no index. A new migration adds one. (#2278)
