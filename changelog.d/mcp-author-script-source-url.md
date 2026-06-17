### Added

- **MCP `author_script` can fetch a support file from a URL.** A data/support
  file too large to inline faithfully in a tool call (e.g. a CSV fixture) can
  now be authored by passing `sourceUrl` (an https URL) instead of `content`;
  the server downloads the body and stores it as the file. Exactly one of
  `content`/`sourceUrl` must be supplied.

### Security

- **The `author_script` URL fetch is SSRF-guarded.** Only `https` is allowed;
  the host is resolved server-side and the fetch is refused if any resulting
  address is loopback / private / link-local (incl. the `169.254.169.254`
  cloud-metadata range) / CGNAT / unique-local / multicast / reserved (IPv4,
  IPv6, and IPv4-mapped/compatible/NAT64 forms are normalised first); redirects
  are not followed; the body is capped at 8 MB while streaming; and the request
  is bounded by connect/read/overall timeouts. The fetch runs only after the
  caller is authorized for the assignment's course, and the address-range logic
  is exhaustively unit-tested (`BlockedIPClassifier`). No new env var or host
  allowlist is introduced; the one residual is a theoretical DNS-rebinding TOCTOU
  window (AsyncHTTPClient re-resolves the host), narrowed by disallowing
  redirects.
