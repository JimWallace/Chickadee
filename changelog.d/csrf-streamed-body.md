### Fixed

- **CSRF no longer rejects form POSTs whose body arrives as a stream.** Vapor
  only delivers a pre-collected body when the entire body lands in the same
  channel read as the request head; a form POST split across TCP reads (routine
  on real networks/proxies, and guaranteed for chunked transfer-encoding) was
  dispatched to the CSRF middleware with a still-streaming body, so the
  synchronous `_csrf` body read failed and the request 403'd
  "No CSRF token provided." even though the field was on the wire — the
  intermittent, production-only failure behind the TA's extension-grant report
  (#868). The token retrieval now collects the body (same size cap as the
  route's own collect step) before reading the field, and a live-socket
  regression test pins the streamed-body path.
