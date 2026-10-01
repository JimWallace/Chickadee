# APIServer

The Vapor application behind `chickadee-server`: the REST API the runner and
instructors use, the Leaf web UI, authentication (local accounts, OIDC SSO and
LTI 1.3), course and assignment management, submission intake and results, the
embedded JupyterLite editor routes, the MCP authoring and admin-diagnostics
servers, the BrightSpace and GitHub integrations, and the background sweeps.

Layout: `Routes/` (handlers), `Services/` (background work and stores),
`Helpers/` and `Utilities/` (shared logic), `Models/` and `Migrations/`
(Fluent), `Middleware/`, `MCP/`, `LTI/`, `GitHub/`, `Configuration/`
(`AppConfig`, the one reader of environment variables) and `Bootstrap/`.

Read [CLAUDE.md](../../CLAUDE.md) for the design decisions, the REST API
summary and the auth model, and
[docs/architecture.md](../../docs/architecture.md) for the system shape.
Operator settings are in [deploy/README.md](../../deploy/README.md).
