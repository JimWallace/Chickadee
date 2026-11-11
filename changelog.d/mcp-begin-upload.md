### Added

- **MCP `begin_upload`: deliver a large local file byte for byte.** An agent calls `begin_upload` for a course, PUTs the file to the returned URL with `curl -T` and the single-use upload token as a bearer header, and passes the `uploadID` to `author_script`, `create_dataset` or `add_dataset_version` in place of `content` or `sourceUrl`. The upload belongs to the grant and course that began it, takes UTF-8 text up to the 8 MB `sourceUrl` cap, is used up by the write that succeeds, and expires after 30 minutes. See `docs/mcp-file-uploads.md`.
