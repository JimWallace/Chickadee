// APIServer/Services/VisibilityAudit.swift
//
// Who changes an assignment's visibility, for its audit row (#2489).
//
// The functions that change visibility for a person's action take one and
// write the row themselves, so no door can open or close an assignment
// unrecorded. Before, the routes wrote the row: the web `/open` route and the
// Save close wrote none, and the MCP content-edit close wrote none. The
// scheduled open and close (`AssignmentDeadlineService`) are not a person's
// action and write no row.

import Core
import Foundation
import Vapor

struct VisibilityAudit {
    /// The door the change came through, recorded as the row's `via`.
    enum Origin: String {
        case web
        case mcp
    }

    let context: any AuditContext
    let origin: Origin
    /// Why the change happened, when it is a side effect of another action
    /// (a Save or a content edit closes an open assignment).
    var reason: String?

    static func web(_ req: Request, reason: String? = nil) -> VisibilityAudit {
        VisibilityAudit(context: req, origin: .web, reason: reason)
    }

    static func mcp(_ context: ToolContext, reason: String? = nil) -> VisibilityAudit {
        VisibilityAudit(context: context.request, origin: .mcp, reason: reason)
    }

    /// Writes the row when `assignment`'s visibility is no longer `previous`.
    func recordChange(of assignment: APIAssignment, from previous: AssignmentVisibility) async {
        guard assignment.visibility != previous else { return }
        var metadata = ["visibility": assignment.visibility.rawValue, "via": origin.rawValue]
        if let reason { metadata["reason"] = reason }
        await AuditLogger.recordAssignmentLifecycle(
            .assignmentVisibilityChanged, assignment: assignment, metadata: metadata, on: context)
    }
}
