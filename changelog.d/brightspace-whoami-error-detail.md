### Fixed

- **BrightSpace "Test connection" now shows the real error.** A failed `whoami`
  surfaced as Swift's generic `"The operation could not be completed.
  (… error N.)"` because `BrightSpaceSyncError` wasn't a `LocalizedError`. It now
  is, and `whoamiFailed` carries D2L's response body — so the admin/instructor
  panels report the actual HTTP status and message (e.g. a 403 "Timestamp out of
  range" vs. an egress-proxy denial). The CLI helper prints the same detail.
