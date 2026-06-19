### Changed

- **BrightSpace/Valence client hardened against UW's reference library.** The
  D2L request layer in `BrightSpaceAPIClient` now negotiates the API version per
  product (`GET /d2l/api/{lp,le}/versions/` → `LatestVersion`, cached; env pins
  `BRIGHTSPACE_LP_API_VERSION` / `BRIGHTSPACE_LE_API_VERSION` override) instead
  of hardcoding a version the LMS may not support — a too-high version 404s every
  call and masks the real cause. Fallback floors moved to UW-known-good values
  (`lp 1.47`, `le 1.75`). The classlist read now follows `/classlist/paged/`
  across all pages (both Valence paging conventions) so large courses aren't
  silently truncated. A `403 "Timestamp out of range"` now teaches the client its
  clock skew and retries once. Signing-path extraction no longer silently sends
  an unsigned request when `URL(string:)` declines to parse. Ported from UW IST's
  `learn_api` / `d2lvalence` reference client; pinned by `BrightSpaceTransportTests`.
