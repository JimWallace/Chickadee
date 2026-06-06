### Changed

- **MCP tool layer consolidation.** Extracted the assignment-resolution
  prologue (`requireAssignment` / `authorizedAssignment` /
  `authorizedAssignmentAndSetup` on `ToolContext`) and the post-edit finalize
  sequence (`applySuiteEditMapped` / `finalizeContentEdit` in
  `ContentEditClose`) that ~20 MCP content tools had copy-pasted. The
  close→retest→revalidate ordering and the per-tool error strings now live in
  one place each instead of being a copy-paste convention. No behaviour change
  (net ~290 fewer lines).
- **Shared base64url + notebook-shape helpers.** The four hand-rolled base64url
  encoders (SSO/PKCE, OAuth, ES256 JWT, BrightSpace HMAC) now share
  `Data.base64URLEncodedString()` / `String.base64ToBase64URL()`, and the
  notebook `cellCount` / `validateNotebookShape` helpers duplicated across five
  MCP tools are now shared. Identical output.

### Fixed

- **New-assignment publish due date now uses the Waterloo timezone.** The draft
  publish path parsed a no-seconds `datetime-local` value in the server's
  default zone instead of `America/Toronto`, shifting the due date by the UTC
  offset; it now reuses the shared `parseDueDate` parser like the edit form.
