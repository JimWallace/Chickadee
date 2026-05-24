### Changed

- **MCP actions are audited as `<username>-MCP`.** Every MCP tool call is now
  recorded in the admin audit log under the subject's username suffixed with
  `-MCP` (e.g. `jsmith-MCP`), so agent-made changes are tracked separately from
  the instructor's own web actions. The token subject itself is unchanged for
  authorization / course-scoping.
- **MCP service-account UI is tied to the auth mode.** When SSO is active
  (`AUTH_MODE` ≠ `local`), the admin MCP panel hides manual service-account
  creation — instructors authorize agents through the SSO browser flow, and the
  Connected Agents table + audit log are the tracking surface. Local-auth
  deployments keep service-account creation.
