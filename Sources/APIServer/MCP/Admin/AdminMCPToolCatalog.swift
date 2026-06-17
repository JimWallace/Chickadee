// APIServer/MCP/Admin/AdminMCPToolCatalog.swift
//
// The tools exposed over the admin diagnostic MCP surface — read-only
// operational diagnosis only.  Nothing here touches student data, grades,
// enrolment, or content authoring.  Parallel to `MCPToolCatalog.live` (the
// content surface); the two catalogs never mix.

/// The admin diagnostic tool catalog.
enum AdminMCPToolCatalog {
    static var live: DiagnosticToolRegistry {
        DiagnosticToolRegistry([
            GetDeploymentInfoTool().erased(),
            GetMetricsSnapshotTool().erased(),
            GetHealthAlertsTool().erased(),
            GetBrowserDiagnosticsTool().erased(),
        ])
    }
}
