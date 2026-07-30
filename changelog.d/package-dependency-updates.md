### Changed

- **Swift dependency refresh.** `swift package update` across the server graph:
  Vapor 4.121.4 → 4.122.0 (adds an HTTPServer idle-connection timeout option),
  Leaf 4.5.1 → 4.5.2 with LeafKit 1.14.2 → 1.14.3 (clearer built-in tag errors
  only — the multi-`#extend` parser bug is *not* fixed upstream, so the editor
  template decomposition stays on hold), async-http-client 1.34.0 → 1.36.0,
  swift-crypto 4.5.0 → 4.5.1, SwiftLintPlugins 0.64.0 → 0.65.0 (no new lint
  rules; safe under `--strict`), and refreshed transitives (swift-nio 2.101.3,
  fluent-kit 1.57.0, jwt-kit 5.6.0, postgres-kit 2.16.1, postgres-nio 1.33.1,
  sqlite-nio 1.13.0, swift-log 1.14.0, among others). `Package.swift` ranges
  already allowed every bump, so this only moves `Package.resolved`.
