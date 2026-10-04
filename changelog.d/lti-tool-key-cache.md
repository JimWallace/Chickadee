### Changed

- **The LTI tool key loads through `SingleFlightCache`.** `LTIToolKeyProvider` was a second copy of `SingleFlightCache` with an infinite TTL. It is now `LTIToolKeyCache`, a typealias with an infinite TTL, the same pattern as `MetricsCardCache`. `SingleFlightCache` moves from `Diagnostics/` to `Helpers/`, because it is no longer only a diagnostics type. Behaviour does not change (#1928).
