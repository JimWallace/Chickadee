### Security

- **Browser results are accepted only for browser-graded assignments.** `POST /api/v1/submissions/browser-result` stored a browser-computed collection for a worker-graded assignment too, so an enrolled student could post any grade for one. It now answers 400 before anything is stored.
- **The per-user notebook folder check matches the path the file server resolves.** `UserFileNamespaceMiddleware` compared the raw URL, so `//`, `./` or a percent-encoded segment skipped it and served another user's notebook with no login. It now percent-decodes, collapses the path and lowercases it first.
- **MCP course access needs a staff role in the target course.** A TA in one course who was a student in another could read the second course's solution and secret tests through the MCP read tools. A human caller now needs TA or above in the course; admins and `mcp` service accounts keep enrollment-only access.
- **The login and MCP OAuth rate limiters key on the address the proxy saw.** `clientIPAddress` read the first `X-Forwarded-For` entry, which the client chooses. It now reads the last, as `clientNetwork` does. The audit log's address follows.
- **Course bundle import confines the starter notebook path.** A bundle's `notebookFilename` now goes through `bundleEntryURL`, so a `../` name cannot copy a server file in.
