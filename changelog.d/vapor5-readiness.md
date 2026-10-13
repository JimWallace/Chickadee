### Changed

- **Preparation for Vapor 5.** The server no longer uses event-loop API: blocking work, the MCP support-file client and the GitHub commit-status post run without an event loop. The last two synchronous lifecycle hooks are async. Every body decode, of a request or of a client response, goes through an async `decodeContent` helper, and client-response text goes through `bodyText`. A new guard, `scripts/check-vapor5-readiness.sh`, stops new event-loop code and direct `content.decode` calls. Behaviour does not change. The plan and what is left are in `docs/vapor-5-migration.md`.
