-- Least-privilege PostgreSQL role for the Chickadee MCP path.
--
-- Defence-in-depth for the student-data wall (compliance remediation P0-1,
-- option 2). The in-process boundary (MCPStudentDataBoundary + the wall guard
-- test) is the primary enforced control; this role makes "the MCP path cannot
-- read student submissions, grades, or PII" true at the DATABASE layer too.
--
-- How it is used: point the server at this role with
--   MCP_DATABASE_USER=chickadee_mcp
--   MCP_DATABASE_PASSWORD=...
-- which registers a dedicated connection pool (DatabaseID.mcp) that every MCP
-- tool query runs on (see Sources/APIServer/Utilities/DatabaseConfiguration.swift
-- and ToolContext.db). The main app keeps using its own (owner) role, so the
-- web UI, worker, and migrations are unaffected. The MCP audit row, the
-- content-edit re-grade, and the acting-user personalization-seed bookkeeping
-- (assignment_personalization_seeds, via ToolContext.mainDB) all run on the
-- main (owner) pool, not this one -- so none of them need a grant here.
--
-- IMPORTANT: review and TEST this against your schema before production use.
-- Grants must cover everything the MCP write tools do; a missing grant surfaces
-- as a tool failure. Run as a superuser / the database owner. Replace the
-- password and (if you use a non-public schema / search_path) the schema name.

\set mcp_role 'chickadee_mcp'

-- 1. The role (login, no inherited superuser/createdb).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chickadee_mcp') THEN
        CREATE ROLE chickadee_mcp LOGIN PASSWORD 'CHANGE-ME';
    END IF;
END$$;

GRANT USAGE ON SCHEMA public TO chickadee_mcp;

-- 2. Authoring tables — full DML (the MCP tools create/edit this content).
GRANT SELECT, INSERT, UPDATE, DELETE ON
    courses, course_sections, assignments, test_setups, assignment_requirements
    TO chickadee_mcp;

-- 3. Identity / enrolment — SELECT only, needed for authorization
--    (subject -> role, and per-course enrolment checks). No write.
GRANT SELECT ON users, course_enrollments TO chickadee_mcp;

-- 4. Submissions / results — SELECT only, and Row-Level Security restricts what
--    the role can see to the instructor's own VALIDATION runs. Even if a future
--    MCP query forgot the in-app kind filter, the database returns no student
--    rows. The table owner (the main app role) bypasses RLS, so the web app and
--    worker are unaffected.
--
--    result_collections (added by #1176, v0.4.587) holds the serialized
--    TestOutcomeCollection blob that used to live on results.collection_json;
--    get_validation_result reads it via loadCollectionJSON. Deployments that
--    applied this file before v0.4.611 must re-run this section: without the
--    grant, every get_validation_result call fails with "permission denied for
--    table result_collections".
GRANT SELECT ON submissions, results, result_collections TO chickadee_mcp;

ALTER TABLE submissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mcp_validation_submissions ON submissions;
CREATE POLICY mcp_validation_submissions ON submissions
    FOR SELECT TO chickadee_mcp
    USING (kind = 'validation');

ALTER TABLE results ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mcp_validation_results ON results;
CREATE POLICY mcp_validation_results ON results
    FOR SELECT TO chickadee_mcp
    USING (EXISTS (
        SELECT 1 FROM submissions s
        WHERE s.id = results.submission_id AND s.kind = 'validation'
    ));

ALTER TABLE result_collections ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mcp_validation_result_collections ON result_collections;
CREATE POLICY mcp_validation_result_collections ON result_collections
    FOR SELECT TO chickadee_mcp
    USING (EXISTS (
        SELECT 1 FROM results r
        JOIN submissions s ON s.id = r.submission_id
        WHERE r.id = result_collections.result_id AND s.kind = 'validation'
    ));

-- 5. Everything else is DENIED by omission — no GRANT is issued, so the role
--    cannot touch any of these student-data tables:
--      grade_overrides, client_diagnostics, submission_diagnostics,
--      job_execution_metrics, assignment_extensions, assignment_participations,
--      assignment_personalization_seeds, class_achievements, achievement_results,
--      user_activity_events, brightspace_sync_log, pre_enrollments, audit_log,
--      request_metrics, runner_profiles, runner_snapshots, oauth_* ...
--    Do NOT add blanket "GRANT ... ON ALL TABLES" — that would defeat the wall.
--
--    assignment_personalization_seeds STAYS DENIED. The MCP personalization
--    tools (update_global_inputs, update_section_variables,
--    preview_personalization) DO ensure the acting account's own per-assignment
--    seed, but that bookkeeping runs on the MAIN (owner) pool via
--    ToolContext.mainDB — never this role — so it needs no grant here. (If you
--    applied the temporary stopgap
--        GRANT SELECT, INSERT ON assignment_personalization_seeds TO chickadee_mcp;
--    REVOKE it after deploying the build that routes the seed write to the owner
--    pool:
--        REVOKE SELECT, INSERT ON assignment_personalization_seeds FROM chickadee_mcp;
--    Leaving the grant in place would re-open the very table this wall denies.)

-- 6. Verify (run as chickadee_mcp):
--      SELECT count(*) FROM submissions;            -- only validation rows
--      SELECT * FROM grade_overrides LIMIT 1;       -- must ERROR: permission denied
--      SELECT * FROM users LIMIT 1;                 -- allowed (authz)
--      SELECT * FROM assignment_personalization_seeds LIMIT 1;
--                                                   -- must ERROR: permission denied
--                                                   -- (seed bookkeeping runs on the owner pool)
