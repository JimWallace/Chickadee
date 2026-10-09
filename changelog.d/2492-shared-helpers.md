### Changed

- **Small helpers are written once.** ISO 8601 dates use `iso8601String` and `iso8601Date` (in Core) instead of some fifty inline formatters; manifests decode through `decodeManifest`, never a plain `JSONDecoder`; the web redirects and the BrightSpace auth URL share `urlEncode`; the admin alerts and retention pages share `adminNoticeRedirect`; and both "does this zip carry a notebook" checks share one predicate (#2492).
