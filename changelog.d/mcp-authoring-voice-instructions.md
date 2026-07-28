### Added

- **MCP authoring-voice guide + per-course agent guidance.** The content MCP
  server's `initialize` instructions now end with a fixed house authoring-voice
  guide (textbook register, imperative/declarative phrasing; no exclamation
  marks, emoji, or cheerleading — warmth reserved for acknowledging genuine
  difficulty), so agents authoring assignment content write in a consistent
  university-level voice. On top of it, each course can set its own tone: a new
  **MCP tab** on the instructor dashboard (`/instructor/mcp`) lets a course's
  instructors edit per-course guidance (`courses.mcp_instructions`, 4000-char
  cap, TAs see it read-only, saves audited), and the server appends each
  authorable course's text — labelled by course code — to the `initialize`
  instructions for accounts holding TA+ (or admin) in that course. Advisory by
  design: no tool descriptions, scopes, capabilities, or grading behaviour
  change, and the admin diagnostic MCP surface is untouched. The same voice
  guide is mirrored into `CLAUDE.md` ("Voice and Register") so repo-side
  authoring follows the identical standard.
