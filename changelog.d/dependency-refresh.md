### Changed

- **Dependabot watches npm and pip.** It covered `swift`, `docker` and
  `github-actions` only, so ESLint, Playwright, esbuild, the CodeMirror
  vendoring inputs and the JupyterLite build pins were never tracked. Swift and
  Actions updates are now grouped to keep a quiet period from producing one PR
  per transitive pin; SwiftLint is deliberately excluded from that grouping,
  because `swiftlint.sh --strict` turns a new rule in a patch release into a
  red `format-lint`.
- **Swift dependency pins refreshed.** Sixteen pins move, all patch or minor —
  Vapor 4.122.1, SwiftNIO 2.102.0, JWTKit 5.7.1, swift-log 1.15.1,
  swift-crypto 4.5.2, swift-system 1.8.1 and related. JWTKit 5.7.1 asserts that
  an HS256 key is at least its 32-byte digest size; the only key affected was an
  11-byte dummy the SSO tests sign mock ID tokens with, since the server itself
  signs with ECDSA and verifies against fetched JWKS.
