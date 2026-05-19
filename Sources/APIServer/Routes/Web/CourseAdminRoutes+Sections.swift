// APIServer/Routes/Web/CourseAdminRoutes+Sections.swift
//
// Section-management handlers.  Phase 2 of the audit refactor moved them
// from `AssignmentRoutes` onto `CourseAdminRoutes`; the file name still
// starts with `AssignmentRoutes+` for blame continuity until the next
// rename pass.

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
        let idStr = try assignmentPublicIDParameter(from: req)
        guard let assignment = try await assignmentByPublicID(idStr, on: req.db),
            assignment.courseID == courseID
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }
        let body = (try? req.content.decode(MoveBody.self))
        let newSectionID: UUID? = try await resolveSectionID(body?.sectionID, courseID: courseID, db: req.db)
        assignment.sectionID = newSectionID
        try await assignment.save(on: req.db)

        // When moving into a named section, sync the test setup's grading mode
        // to match the section's defaultGradingMode.  Moving to "ungrouped"
        // (nil section) leaves the grading mode unchanged.
        if let sectionUUID = newSectionID,
            let section = try await APICourseSection.find(sectionUUID, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        {
            let mode = section.defaultGradingMode  // "browser" | "worker"
            if var dict = (try? JSONSerialization.jsonObject(with: Data(setup.manifest.utf8))) as? [String: Any],
                (dict["gradingMode"] as? String) != mode
            {
                dict["gradingMode"] = mode
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                    let json = String(data: data, encoding: .utf8)
                {
                    setup.manifest = json
                    try await setup.save(on: req.db)
                }
            }
        }

        return .ok
    }
}
