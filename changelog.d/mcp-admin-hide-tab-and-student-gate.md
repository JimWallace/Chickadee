### Changed

- **Admin "MCP" tab is hidden when `MCP_ENABLED=false`.** The MCP nav tab no
  longer appears in the admin panel unless the endpoint is enabled (new
  `#mcpEnabled()` Leaf tag reads the boot-time flag).

### Security

- **Students are excluded from the MCP interface at the tool layer.** MCP tool
  calls now require the token subject to be an instructor, admin, or `mcp`
  service account — never a student. Students already can't complete the
  `/oauth/authorize` consent flow (it requires instructor), so this is
  defence-in-depth: the guarantee no longer rests solely on token issuance.
