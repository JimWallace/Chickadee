### Changed

- **swift-crypto bumped 3.15.1 → 4.5.0** (#916, supersedes #580). The 4.x
  line's breaking change is dropping Swift < 6.1 (Chickadee is on 6.3) and it
  includes the upstream CVE-2026-28815 X-Wing HPKE fix. The HMAC/SHA-256 and
  JWT APIs Chickadee uses are unchanged; verified against the MCP OAuth
  (ES256), SSO, and worker HMAC test suites.
