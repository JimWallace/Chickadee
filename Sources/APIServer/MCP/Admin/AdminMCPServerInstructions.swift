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

        Getting started:
        - Call get_deployment_info first to confirm the surface is live and see \
        the version it's running.
        - A typical flow is "is anything wrong?" (get_health_alerts) → "show me \
        the underlying numbers" (get_queue_state / list_runners / get_metrics_*) \
        → "what was logged?" (query_logs / get_browser_diagnostics). Each tool's \
        own description says exactly what it returns and when to prefer it over a \
        neighbour.
        - For trends over time, prefer get_metrics_card_series (the fixed \
        dashboard windows) or get_metrics_timeseries (an arbitrary window, plus \
        HTTP request latency); get_metrics_snapshot is the single point-in-time \
        number. tools/list only shows the tools your grant's scope covers.

        What's available, by area:
        - Deployment: get_deployment_info (version + capability surface); \
        get_deploy_status (the zero-downtime auto-deploy daemon's current state — \
        live version, latest release seen, paused flag, pending major approval) \
        and get_deploy_history (recent deploy / rollback events). Both are \
        read-only views of the daemon's status files; deploy control \
        (pause/approve/rollback) is a host-side action, not exposed here.
        - Runners: list_runners (the fleet) and get_runner_detail (one runner's \
        capability profile + aggregate per-stage timing + cache-hit rate + \
        recent snapshots — never the per-job rows).
        - Queue: get_queue_state (pending depth, in-flight, oldest-pending age, \
        stuck-submission count).
        - Metrics: get_metrics_snapshot (point-in-time), get_metrics_card_series \
        (the dashboard's fixed 24h/7d/30d sparklines), get_metrics_timeseries \
        (a flexible window/bucket, including HTTP request latency), and \
        get_request_metrics (slowest routes / status-class counts).
        - Activity: get_active_users_series (distinct active users per bucket); \
        get_instructor_card_series (one course's submission / active-student / \
        active-assignment / browser-error counts, scoped by an explicit \
        courseCode filter).
        - Errors & logs: get_browser_diagnostics, query_logs, get_health_alerts.
        - Storage: get_storage_usage (footprint by component + per-assignment).
        - Integrations & security: list_connected_agents (MCP OAuth grants), \
        get_brightspace_sync_status (grade-push health), query_audit_log \
        (activity COUNTS by action/category only).

        Every one of these returns aggregates or redacted records by \
        construction — never a student identity, grade, submission content, or \
        enrollment. Where a source table carries such data (browser \
        diagnostics, brightspace sync, the audit log, per-job metrics), the tool \
        omits it: query_audit_log returns counts only (no actor/IP/metadata), \
        get_brightspace_sync_status drops the student username and grade, and \
        get_runner_detail exposes only aggregate timing, not the per-job rows \
        the web page shows.
        """
}
