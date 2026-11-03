// APIServer/Routes/Web/CourseAdminRoutes+Sections.swift
//
// Section-management handlers.  Phase 2 of the audit refactor moved them
// from `AssignmentRoutes` onto `CourseAdminRoutes`; the file name still
// starts with `AssignmentRoutes+` for blame continuity until the next
// rename pass.
//
// Course-section structure is **instructor-level** (#417): it is course
// LIFECYCLE, not assignment content, so every handler here except the reorder
// calls `requireCourseWriteAccess(atLeast: .instructor)` on top of the `/instructor`
// group's `ActiveCourseStaffMiddleware` (which only proves TA+ in the caller's
// *active* course).  The floor is stated in three other places — the
// convention comment on `evaluateCourseWrite`, the header of
// `CourseAdminRoutes+ContentItems.swift` ("course-section structure stays
// instructor-level"), and the MCP twins in `CourseSectionTools.swift`, whose
// own comments read "instructor-level (#417), matching the web".  The web did
// NOT match until the derived authorization matrix landed: these five handlers
// scoped their writes to the active course but never checked the role, so a TA
// could create, rename, reorder and delete a course's sections and move
// assignments between them — and, lacking `requireCourseWriteAccess`, could do
// it in an archived course.  `RouteAuthorizationMatrixTests` is what surfaced
// it, and is what holds the floor now.
//
// The reorder is the one exception (#2713): reordering is display
// organization, so every reorder kind, web and MCP, floors at `.ta`
// (`SortOrderRenumbering.roleFloor`).
//
// The field rules and the writes are in `CourseSectionService`, which the MCP
// tools share (#2769). These handlers authorize, decode the form, and map a
// `CourseSectionError` to `WebAssignmentError`.

import Core
import Fluent
import Vapor

extension CourseAdminRoutes {

    // MARK: - POST /instructor/sections

    @Sendable
    func createSection(req: Request) async throws -> Response {
        struct CreateSectionBody: Content {
            var name: String
            var defaultGradingMode: String
        }
        let user = try req.auth.require(APIUser.self)
        let courseID = try await req.requireActiveCourseForWrite(
            user, atLeast: DashboardRoleFloor.manageSections, action: "managing sections"
        ).requireID()
        let body = try await req.decodeContent(CreateSectionBody.self)
        let draft: CourseSectionDraft
        do {
            draft = try CourseSectionDraft(name: body.name, defaultGradingMode: body.defaultGradingMode)
        } catch {
            throw Self.webError(error)
        }
        _ = try await CourseSectionService.create(draft, courseID: courseID, on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/sections/reorder

    /// Persists the order of the active course's sections. `sectionIDs` must
    /// name every section; `SortOrderRenumbering` holds the rules and the
    /// `.ta` floor (#2713). AJAX (returns `.ok`).
    @Sendable
    func reorderSections(req: Request) async throws -> HTTPStatus {
        struct ReorderBody: Content {
            var sectionIDs: [String]
        }
        let user = try req.auth.require(APIUser.self)
        guard let course = try await req.activeCourseForWrite(user, atLeast: SortOrderRenumbering.roleFloor) else {
            return .ok
        }
        let courseID = try course.requireID()
        let body = try await req.decodeContent(ReorderBody.self)
        do {
            let ids = try body.sectionIDs.map(SortOrderRenumbering.sectionID)
            _ = try await SortOrderRenumbering.renumberSections(ids, inCourse: courseID, on: req.db)
        } catch let error as ReorderError {
            throw WebAssignmentError.invalidParameter(name: "sectionIDs", reason: error.reason)
        }
        return .ok
    }

    // MARK: - POST /instructor/sections/:sectionID/rename

    @Sendable
    func renameSection(req: Request) async throws -> Response {
        struct RenameSectionBody: Content {
            var name: String
            var defaultGradingMode: String
        }
        let user = try req.auth.require(APIUser.self)
        let courseID = try await req.requireActiveCourseID(for: user, action: "managing sections")
        guard let sectionIDStr = req.parameters.get("sectionID"),
            let sectionUUID = UUID(uuidString: sectionIDStr)
        else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        guard let section = try await APICourseSection.find(sectionUUID, on: req.db),
            section.courseID == courseID
        else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        try await requireCourseWriteAccess(
            caller: user, courseID: section.courseID, atLeast: DashboardRoleFloor.manageSections, db: req.db)
        let body = try await req.decodeContent(RenameSectionBody.self)
        let edit: CourseSectionEdit
        do {
            edit = try CourseSectionEdit(name: body.name, defaultGradingMode: body.defaultGradingMode)
        } catch {
            throw Self.webError(error)
        }
        try await CourseSectionService.update(section, with: edit, on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/sections/:sectionID/delete

    @Sendable
    func deleteSection(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseID = try await req.requireActiveCourseID(for: user, action: "managing sections")
        guard let sectionIDStr = req.parameters.get("sectionID"),
            let sectionUUID = UUID(uuidString: sectionIDStr)
        else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        guard let section = try await APICourseSection.find(sectionUUID, on: req.db),
            section.courseID == courseID
        else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        try await requireCourseWriteAccess(
            caller: user, courseID: section.courseID, atLeast: DashboardRoleFloor.manageSections, db: req.db)
        // FK SET NULL: assignments in this section will have section_id → NULL (ungrouped).
        try await CourseSectionService.delete(section, on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/:assignmentID/section

    @Sendable
    func moveToSection(req: Request) async throws -> HTTPStatus {
        struct MoveBody: Content {
            var sectionID: String?  // UUID string, or "" / absent = ungrouped
        }
        let user = try req.auth.require(APIUser.self)
        let courseID = try await req.requireActiveCourseID(for: user, action: "managing sections")
        let assignment = try await loadAssignment(req)
        guard assignment.courseID == courseID else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignment.publicID)'")
        }
        // `loadAssignment` is the deliberately unauthorized loader, so this is
        // the only role check on the path. Which section an assignment sits in
        // is course structure, so the floor matches `set_assignment_course_section`.
        try await requireCourseWriteAccess(
            caller: user, courseID: assignment.courseID, atLeast: DashboardRoleFloor.manageSections, db: req.db)
        let body = (try? await req.decodeContent(MoveBody.self))
        let newSectionID: UUID? = try await resolveSectionID(body?.sectionID, courseID: courseID, db: req.db)
        // Appends to the destination lane (the DnD client follows with a
        // reorder to place it exactly) and adopts a named section's default
        // grading mode where the manifest allows it. Ungrouping leaves the
        // grading mode unchanged.
        try await CourseSectionService.moveAssignment(assignment, toSection: newSectionID, on: req.db)
        return .ok
    }

    /// The form error for a refused course section.
    private static func webError(_ error: CourseSectionError) -> WebAssignmentError {
        .invalidParameter(name: error.field, reason: error.description)
    }
}
