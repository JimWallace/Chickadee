### Added

- **Tests for the runner-facing API gaps.** A new suite covers the 409 for a workerID that another host holds, the language gate refusing a runner end to end, the download base URL order (configured URL, forwarded headers, Host header, bind address), unsigned heartbeat and result requests that store nothing, the class corpus and best-effort result kinds, and the claim on a store without SQL. No product code changed.
