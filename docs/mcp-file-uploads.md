# Staged MCP file uploads (`begin_upload`)

An MCP agent that authors course content often has the file it needs on its
own machine: a CSV dataset it built, a helper module, a fixture. Before
`begin_upload`, the write tools that take file bytes (`author_script` for a
support file, `create_dataset` and `add_dataset_version` for the course
library) accepted two sources:

- `content`, inline in the tool call. The agent has to generate every byte as
  output tokens. At hundreds of KB that is slow, and it is not byte-exact: a
  model re-typing a 0.5 MB CSV drops or alters rows.
- `sourceUrl`, which the server fetches under the SSRF guard
  (`SupportFileURLFetcher`). The file must already be on a public https host.

`begin_upload` adds a third source: the agent's shell sends the file's exact
bytes to the server, and the write tool names them by `uploadID`.

## How an agent uses it

```text
begin_upload {"courseCode": "HLTH230"}
  -> {"uploadID": "6F1C…", "uploadURL": "https://chickadee.example/mcp/uploads/6F1C…", "uploadToken": "…", …}
curl -sS -T reads.csv -H "Authorization: Bearer <uploadToken>" "https://chickadee.example/mcp/uploads/6F1C…"
  -> {"uploadID": "6F1C…", "sizeBytes": 524288, "sha256": "…"}
author_script {"assignmentPublicID": "AB12CD", "filename": "reads.csv", "tier": "support", "uploadID": "6F1C…"}
```

`create_dataset` and `add_dataset_version` take `uploadID` the same way, with
`filename` (a bare name ending in `.csv`), since an upload has no URL to name
it. The result's `curlExample` is the curl line with the URL and token filled
in. The PUT's `sha256` lets the agent compare against `shasum -a 256` of the
local file.

## Rules

| Rule | Where |
|---|---|
| `content:write`, TA and above in the course (the dataset-library floor) | `BeginUploadTool` |
| The upload belongs to the grant that began it: the token subject and the OAuth client. Another account, another client, or a service token of the same account gets "no pending upload", as for an id that does not exist | `MCPUploadService.load` |
| The upload belongs to one course; a write in another course is refused | `MCPUploadService.load` |
| The PUT must present the upload token; a wrong or missing token answers as an unknown upload | `MCPUploadRoutes`, `MCPUploadService.receive` |
| One PUT per upload (an atomic claim, so two concurrent PUTs cannot both store), of at most 8 MB (`SupportFileURLFetcher.maxBytes`, the `sourceUrl` cap), non-empty UTF-8 text | `MCPUploadService.receive`, the route's body limit; a refused body claims nothing, so a good file can follow |
| A dataset upload must also be a CSV with a header row | `CourseDatasetService`, as for every version |
| Single use: the write tool deletes the upload once its write succeeds. A refused write leaves it, so the agent can fix the call and retry | `consumeMCPUpload` |
| Expires 30 minutes after `begin_upload`. Expired rows are deleted when the grant begins another upload, and by the hourly MCP OAuth reaper | `MCPUploadService.purgeExpired`, `reapExpiredMCPOAuthRecords` |
| At most 10 live uploads per grant, so a loop cannot fill the database | `MCPUploadService.maxOpenPerOwner` |

No environment variable controls any of these: the cap, the lifetime and the
per-grant limit are constants.

## Why a one-off token, and why in a header

The upload route, `PUT /mcp/uploads/:uploadID` (POST also works, for
`curl --data-binary @file`), takes no OAuth bearer and no session. Its
credential is the upload token from `begin_upload`, sent as
`Authorization: Bearer <uploadToken>`. The reason is practical: the agent's
MCP client holds the OAuth access token, and the agent's shell does not, so a
route that wanted the OAuth token would leave the agent with no way to call it.
The upload token is returned in the tool result, so the agent can pass it to
`curl`. It is as strong as an OAuth code and is treated like one: 256 bits,
only its SHA-256 is stored, it is bound at creation to a grant and a course, it
takes one PUT, and it expires.

The token is in a header, not in the URL path, because paths are recorded:
Vapor's route logger writes each request's path at info level into the log
buffer that the admin `query_logs` tool reads, and `RequestTimingMiddleware`
stores paths in `request_metrics`, which `get_request_metrics` reads. A token
in the path of a refused PUT would stay usable, and readable there, until it
expired. The path carries only the upload id, which grants nothing.

The route reads no cookie, so it needs no CSRF token, and a DNS-rebinding page
gains nothing from it.

The URL's origin is the MCP metadata origin (`MCPEndpoints.metadataOrigin`,
from `PUBLIC_BASE_URL` or `MCP_ISSUER`), so the agent reaches the upload at
the host it already talks to.

## Why not chunked base64

The other design considered was a tool that appends base64 chunks to a staging
row (`append_upload_chunk`). It needs no new route, but it does not solve the
problem: the agent still generates every byte as output tokens, now a third
more of them, across many calls. It is no more exact than inline `content`,
only split up. The upload route moves the bytes through the shell, where a
file is copied, not re-typed.

## Storage

The bytes live in the `mcp_uploads` row (`bytea` on Postgres), not on disk, so
an upload received by one server process can be used through another (the
blue-green deploy runs two). Rows are on the owner pool (`ToolContext.mainDB`):
they are grant bookkeeping, like `oauth_*`, and the least-privilege
`chickadee_mcp` role has no grant on the table
(`deploy/sql/mcp-least-privilege-role.sql`).

Failed checks answer in this order: unknown (wrong grant included), expired,
wrong course, not yet uploaded.

Tests: `Tests/APITests/MCP/MCPUploadTests.swift`.
