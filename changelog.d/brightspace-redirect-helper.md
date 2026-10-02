### Changed

- **One `brightspaceRedirect` helper for the BrightSpace instructor routes.** The 32 flash writes and 24 redirects to the page each spelled the same two lines; every mutating handler now ends in one call that sets the flash and redirects (#1714).
