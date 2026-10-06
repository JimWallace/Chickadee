### Removed

- **The admin MCP tools no longer repeat the admin check.** The admin dispatcher runs the admin re-check once for every tool (#1943), but 18 tools still ran it again themselves, so each call checked the user twice. The per-tool lines and their 18 direct-execute tests are gone; `AdminMCPAdminRecheckTests` checks every tool through the dispatcher. (#2333)
