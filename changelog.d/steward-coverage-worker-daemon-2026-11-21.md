### Added

- **Tests for the runner's retry-delay range, stale-claim results and zipped opponents.** New tests check that a retry delay outside 0 ms to one hour falls back to its default and is logged, that a result the server refuses for a stale claim is dropped with its log event, that a zipped champion submission is extracted for a match, and the two error descriptions no test read. No product code changed.
