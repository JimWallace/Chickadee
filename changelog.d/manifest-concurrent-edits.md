### Fixed

- **Two edits to one assignment at the same time no longer lose one.** A manifest edit decoded, changed and saved the whole manifest with no check, so `PUT /achievements` and `PUT /suite`, or two MCP tools, at once kept only the last. The save is now conditional on the manifest it read. When another edit saved first, the edit is applied again on top of it, and after three such races it is refused so the author can retry (#2019).
