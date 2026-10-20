# MCP Server — Area Rules

Claude Code loads this file when it works under `Sources/APIServer/MCP/`. The
rules for the whole repository are in the root `CLAUDE.md`, and the server-wide
rules are in `Sources/APIServer/CLAUDE.md`.

---

**MCP server.** Chickadee is its own MCP server and its own OAuth 2.1
authorization server. `MCP_MODE` (`off` / `read_only` / `read_write`) gates it.
The protocol era is resolved per request (#1218), and `initialize` never
negotiates up to the modern revision. OAuth codes and tokens are stored only as
hashes and are consumed by an atomic conditional `UPDATE`, so a code cannot be
replayed. See `docs/architecture.md` §"MCP surfaces" and
`docs/archive/mcp-2026-07-28-revision.md`. The `initialize` instructions end with the
authoring-voice guide, and a course's instructors can replace it for their
course (root `CLAUDE.md`, "Voice and Register").

**The MCP student-data wall has one gated exception: AI-assisted feedback.**
The `feedback:*` tools read students' written answers (`reflection`-tagged
cells) by pseudonymous handle, and only where an admin turned on the course
gate and an instructor turned on the assignment gate. **No MCP tool may set
either gate** (`MCPAIFeedbackGateTests`). Student-submission access stays in
`MCPStudentDataBoundary`, and the RLS policy in
`deploy/sql/mcp-least-privilege-role.sql` checks both gates. Chickadee still
calls no model API. The instructor AI agents tab (`/instructor/mcp`) records
each staff member's UW-licensed-account attestation; by decision, nothing
enforces it. See [docs/ai-assisted-feedback.md](../../../docs/ai-assisted-feedback.md).

**The MCP surface holds no language names (#1290).** Every language list in
agent-facing copy derives from `allCases` (`MCPLanguageProse`), and
`get_server_info` reports a `languages` payload. `MCPLanguageCoverageTests`
fails on any list that stops short. A new language needs no edit to MCP prose.
See `docs/adding-a-xeus-kernel.md`, compiler-invisible item 8.

**The tier prose is derived too.** A `student` tier was once advertised by the
MCP schema while `TestTier` never had it, so `author_script` accepted it into
its JSON schema and then rejected it at `TestTier(rawValue:)`. The tier prose
now derives from `TestTier.allCases` (`MCPTierProse`, guarded by
`MCPTierCoverageTests`), so neither a phantom nor a truncated list can
reappear.

**The voice guide has two copies.** `MCPServerInstructions.authoringVoice` in
`Protocol/InitializeTypes.swift` and the "Voice and Register" block in the root
`CLAUDE.md` are deliberately identical. Change both together.

**The tool count.** `MCPToolCatalog.live` in
`Transport/MCPServerRegistration.swift` is the source of truth for the number of
tools.
