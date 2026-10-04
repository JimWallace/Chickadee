### Changed

- **The MCP coverage tests read both surfaces.** Four test suites built their own copy of the text an agent reads, and all four read only the content catalog. They now share one helper that also reads the admin catalog, the admin instructions and the doc resources, so a stale list there fails a test. The output-schema structure test reads both catalogs too. `docs/admin-mcp.md` says why most admin tools declare no output schema (#1935).
