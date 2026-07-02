### Changed

- **`MCPOAuthRoutes.swift` split along its endpoint seams (#1122).** The
  ~950-line OAuth 2.1 authorization-server file is now the route table plus
  one file per concern: the authorize/consent flow, dynamic client
  registration, the token endpoint (code exchange + refresh rotation), the
  discovery/metadata surface, and the wire DTOs. No behavior change; the
  endpoint set, error bodies, and token semantics are byte-identical.
