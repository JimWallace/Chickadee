### Added

- **Audit log now covers SSO logins and the full MCP OAuth flow.** The admin
  audit log previously recorded only local username/password logins and a
  handful of admin actions, so deployments using SSO (and the MCP "authorize an
  agent" flow) saw an empty log. New events: SSO login success, SSO account
  provisioning, SSO allowlist role grants, logout, local self-registration,
  MCP consent granted, MCP token issued, MCP refresh-token reuse (theft)
  detection, MCP grant revoke-on-downgrade, MCP dynamic client registration,
  course create/delete, course bundle import/export, bulk enrollment, and
  unenrollment. The previously-defined-but-unwritten `submission.retention_purged`
  action is now emitted when a course deletion purges submissions.

### Changed

- **`/admin/audit` is filterable and human-readable.** Entries now show a
  Category and a plain-language action label alongside the raw identifier, with
  filters for action and actor and a match count, so high-volume events
  (MCP tool calls, logins) no longer crowd out the 200-row view. Timestamps use
  the America/Toronto formatter, matching the rest of the admin UI.
