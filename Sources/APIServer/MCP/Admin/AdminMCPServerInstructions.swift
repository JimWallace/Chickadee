// APIServer/MCP/Admin/AdminMCPServerInstructions.swift
//
// Server-level guidance surfaced in the admin diagnostic surface's `initialize`
// result. Teaches a connecting agent what this surface is for, what it can and
// cannot see, and the hard no-student-data guarantee — the admin analog of
// `MCPServerInstructions` for the content surface.

enum AdminMCPServerInstructions {
    static let text = """
        This is Chickadee's ADMIN DIAGNOSTIC surface — a separate, read-only MCP \
        server for operational diagnosis. It is distinct from the content-authoring \
        MCP server (a different endpoint, audience, and scope) and exists so an \
        authorized agent can help diagnose server errors and operational issues.

        Access model:
        - Read-only. Every tool only reads; nothing here mutates server state. \
        "Fixing" happens through code changes and pull requests, never through \
        this surface.
        - Admin-only. The authenticated account must have the admin role. There is \
        no course scoping — this surface is deployment-wide.
        - Scope: tools require `diagnostics:read`.

        Data guarantee:
        - This surface NEVER exposes student data. No student identities, grades, \
        submissions, submission contents, or enrollment. Diagnostic results are \
        aggregates and redacted records by construction (a student identifier is \
        not reachable through the tools). Assignment/test-setup identifiers and \
        timings/statuses/error text are instructor/operational data and may appear.

        Use the tools to inspect deployment health, runner/queue state, server \
        metrics, browser-error reports, and logs to diagnose problems — then \
        propose fixes as code, outside this surface.
        """
}
