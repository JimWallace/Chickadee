### Fixed

- **MCP resource errors carry their reason and reach the log.** `resources/list` answered every error, a refusal included, with an opaque "Failed to list resources.", and neither resource method logged a server fault. Both now map a refusal to an invalid-params error with its reason, as the tools path does, and log every other error. (#2340)
