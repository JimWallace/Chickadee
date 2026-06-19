### Fixed

- **BrightSpace "Authorize" button really works now (form-action on the right
  response).** The earlier fix relaxed `form-action` on the authorize POST
  response, but the browser enforces `form-action` using the CSP of the page
  that *contains* the form — so the relaxation has to be on the
  `GET /admin/brightspace` render, not the POST. Moved it there (matching the
  MCP consent-page pattern); the button no longer silently does nothing.
