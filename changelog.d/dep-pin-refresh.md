### Changed

- **Dependency maintenance: refreshed transitive pins and tightened manifest floors.**
  Ran `swift package update` to pick up the minor/patch transitive bumps
  Dependabot doesn't manage (it only moves the `Package.swift` floors): `swift-nio`
  2.99.0 → 2.101.0 (+ http2/ssl/extras), `jwt-kit` 5.2.0 → 5.5.0, `swift-collections`
  1.5.0 → 1.6.0, `swift-log` 1.12.0 → 1.13.2, `swift-system` 1.6.4 → 1.7.2,
  `async-http-client` 1.33.1 → 1.34.0, plus `swift-http-types`, `swift-metrics`,
  `swift-asn1`, and `swift-async-algorithms`. Also raised the lagging `from:` floors
  in `Package.swift` to match what's resolved (`vapor` 4.121.4, `swift-argument-parser`
  1.8.2, `SwiftLintPlugins` 0.63.3). No direct-dependency major-version changes; no
  source changes.
