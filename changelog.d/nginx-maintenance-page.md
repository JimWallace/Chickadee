### Added

- **Chickadee-themed maintenance page.** When the server is briefly
  unreachable (e.g. during a restart or update), nginx now serves a
  self-contained, brand-styled "We'll be right back" page
  (`deploy/error-pages/maintenance.html`) instead of the default nginx 502.
  Wired into both `deploy/nginx-docker.conf` and `deploy/nginx.conf` via
  `error_page 502 503 504`; the page auto-refreshes and clears itself once the
  server is healthy again. `/health` and `/mcp` still return real status codes.
