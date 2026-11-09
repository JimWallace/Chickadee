### Fixed

- **A runner's result report may be up to 32 MB, as intended.** `ResultRoutes.resultIngestBodyLimitBytes` set 32 MB so that an over-budget report from an older runner reaches the server-side truncation instead of a 413 that leaves the submission unresolved (#1157). The route used the app default of 10 MB, and the worker HMAC middleware collected at that default too, so the limit never applied. Both now use the ingest limit.
