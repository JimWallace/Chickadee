// APIServer/Routes/Web/CourseAdminRoutes+Sections.swift
//
// Section-management handlers.  Phase 2 of the audit refactor moved them
// from `AssignmentRoutes` onto `CourseAdminRoutes`; the file name still
// starts with `AssignmentRoutes+` for blame continuity until the next
// rename pass.
//
// Course-section structure is **instructor-level** (#417): it is course
// LIFECYCLE, not assignment content, so every handler here calls
// `requireCourseWriteAccess(atLeast: .instructor)` on top of the `/instructor`
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
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "managing sections")
        }
        try await requireCourseWriteAccess(
            caller: user, courseID: courseID, atLeast: .instructor, db: req.db)
        let body = try req.content.decode(CreateSectionBody.self)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Section name must not be empty.")
        }
        let mode = body.defaultGradingMode
        guard mode == "browser" || mode == "worker" else {
            throw WebAssignmentError.invalidParameter(
                name: "defaultGradingMode", reason: "defaultGradingMode must be 'browser' or 'worker'.")
        }
        let maxOrder =
            try await APICourseSection.query(on: req.db)
            .filter(\.$courseID == courseID)
            .max(\.$sortOrder) ?? 0
        let section = APICourseSection(
            name: name, defaultGradingMode: mode, sortOrder: maxOrder + 1, courseID: courseID)
        try await section.save(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/sections/reorder

    @Sendable
    func reorderSections(req: Request) async throws -> HTTPStatus {
        struct ReorderBody: Content {
            var sectionIDs: [String]
        }
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseID = courseState.activeCourseUUID else { return .ok }
        try await requireCourseWriteAccess(
            caller: user, courseID: courseID, atLeast: .instructor, db: req.db)
        let body = try req.content.decode(ReorderBody.self)
        let uuids = body.sectionIDs.compactMap { UUID(uuidString: $0) }
        guard uuids.count == body.sectionIDs.count, !uuids.isEmpty else {
            throw WebAssignmentError.invalidParameter(
                name: "sectionIDs", reason: "Invalid section ID in reorder payload.")
        }
        let sections = try await APICourseSection.query(on: req.db)
            .filter(\.$courseID == courseID)
            .filter(\.$id ~~ uuids)
            .all()
        guard sections.count == uuids.count else {
            throw WebAssignmentError.invalidParameter(
                name: "sectionIDs", reason: "Section set mismatch in reorder payload.")
        }
        let byID = Dictionary(
            uniqueKeysWithValues: sections.compactMap { s -> (UUID, APICourseSection)? in
                guard let id = s.id else { return nil }
                return (id, s)
            })
        for (index, uuid) in uuids.enumerated() {
            guard let section = byID[uuid] else { continue }
            section.sortOrder = index + 1
            try await section.save(on: req.db)
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
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "managing sections")
        }
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
            caller: user, courseID: section.courseID, atLeast: .instructor, db: req.db)
        let body = try req.content.decode(RenameSectionBody.self)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Section name must not be empty.")
        }
        let mode = body.defaultGradingMode
        guard mode == "browser" || mode == "worker" else {
            throw WebAssignmentError.invalidParameter(
                name: "defaultGradingMode", reason: "defaultGradingMode must be 'browser' or 'worker'.")
        }
        section.name = name
        section.defaultGradingMode = mode
        try await section.save(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/sections/:sectionID/delete

    @Sendable
    func deleteSection(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "managing sections")
        }
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
            caller: user, courseID: section.courseID, atLeast: .instructor, db: req.db)
        // FK SET NULL: assignments in this section will have section_id → NULL (ungrouped).
        try await section.delete(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/:assignmentID/section

    @Sendable
    func moveToSection(req: Request) async throws -> HTTPStatus {
        struct MoveBody: Content {
            var sectionID: String?  // UUID string, or "" / absent = ungrouped
        }
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "managing sections")
        }
        let assignment = try await loadAssignment(req)
        guard assignment.courseID == courseID else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignment.publicID)'")
        }
        // `loadAssignment` is the deliberately unauthorized loader, so this is
        // the only role check on the path. Which section an assignment sits in
        // is course structure, so the floor matches `set_assignment_course_section`.
        try await requireCourseWriteAccess(
            caller: user, courseID: assignment.courseID, atLeast: .instructor, db: req.db)
        let body = (try? req.content.decode(MoveBody.self))
        let newSectionID: UUID? = try await resolveSectionID(body?.sectionID, courseID: courseID, db: req.db)
        assignment.sectionID = newSectionID
        // Append to the destination lane's shared (assignment + content) order so
        // the moved assignment doesn't collide with an existing sort_order; the
        // DnD client follows with a reorder to place it exactly.
        assignment.sortOrder = try await nextAssignmentSortOrder(
            courseID: courseID, sectionID: newSectionID, db: req.db)
        try await assignment.save(on: req.db)

        // When moving into a named section, sync the test setup's grading mode
        // to match the section's defaultGradingMode.  Moving to "ungrouped"
        // (nil section) leaves the grading mode unchanged.  Shares
        // `setManifestGradingMode` with the MCP set_grading_mode tool so both
        // paths produce identical (sorted-key) manifest bytes — the
        // manifest-hash retest gate depends on that determinism.
        //
        // An upload-only assignment — or one marking grader-only files —
        // skips the sync rather than failing the move: adopting a browser
        // default would be refused (no notebook page to grade in, or withheld
        // files the browser path would deliver), and a drag into a section is
        // not the place to surface that — the assignment simply keeps worker
        // grading.
        if let sectionUUID = newSectionID,
            let section = try await APICourseSection.find(sectionUUID, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db),
            !(section.defaultGradingMode == GradingMode.browser.rawValue
                && (currentManifestSubmissionMode(setup.manifest) == SubmissionMode.uploadOnly.rawValue
                    || !currentManifestGraderOnlyFiles(setup.manifest).isEmpty))
        {
            _ = try await setManifestGradingMode(setup: setup, to: section.defaultGradingMode, on: req.db)
        }

        return .ok
    }
}
