// APIServer/Routes/Web/InstructorLMSRoutes.swift
//
// The instructor routes that talk to the LMS: the LEARN roster check, the
// BrightSpace tab and its actions, the LTI grade service page, and the
// per-assignment grade push. Carved out of `InstructorDashboardRoutes`
// (#1718): these handlers share nothing with the assignment list, and
// their four files read as one unit. Same `/instructor` group, same
// `ActiveCourseStaffMiddleware`; registered beside the dashboard in
// routes.swift.

import Vapor

struct InstructorLMSRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let r = routes.grouped("instructor")
        // Reconcile the roster against the LEARN classlist (flags dropped students).
        r.get("students", "learn-check", use: studentsLearnCheck)
        // BrightSpace tab: status, grade-item mapping, sync log, manual actions.
        r.get("brightspace", use: brightspacePage)
        r.post("brightspace", "test", use: brightspaceTestConnection)
        // Per-instructor identity: connect your own LEARN account, designate it
        // as this course's sync identity, or disconnect.
        r.post("brightspace", "connect", use: brightspaceConnectAccount)
        r.post("brightspace", "use-my-identity", use: brightspaceUseMyIdentity)
        r.post("brightspace", "disconnect", use: brightspaceDisconnectAccount)
        r.post("brightspace", "bind-org-unit", use: brightspaceBindOrgUnit)
        r.get("brightspace", "grade-objects", use: brightspaceGradeObjects)
        r.post("brightspace", "auto-map", use: brightspaceAutoMap)
        r.post("brightspace", "sync-now", use: brightspaceSyncNow)
        r.post("brightspace", "reconcile-now", use: brightspaceReconcileNow)
        // LMS grades through the LTI grade service (docs/lti-1-3.md, AGS).
        r.get("lti-grades", use: ltiGradesPage)
        r.post("lti-grades", "transport", use: saveLTIGradeTransport)
        r.post("lti-grades", "push-all", use: pushAllLTIGrades)
        // Push one assignment's grades to BrightSpace.
        r.post(":assignmentID", "brightspace", "push-all", use: brightspacePushAllForAssignment)
    }
}
