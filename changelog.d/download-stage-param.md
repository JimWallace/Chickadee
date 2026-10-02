### Fixed

- **Runner download retries name the download the caller started.** `download(url:to:)` inferred its retry stage from the destination filename, so an opponent download for a match or matrix job was logged and retried as `download_testsetup`. The stage is a parameter now (`download_submission`, `download_testsetup`, or the new `download_opponent`), and the log test drives all three (#1793).
