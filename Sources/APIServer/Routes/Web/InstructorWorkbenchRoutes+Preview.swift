// APIServer/Routes/Web/InstructorWorkbenchRoutes+Preview.swift
//
// Preview as student (notebook views NB6b): the students the workbench can
// preview, and GET /instructor/:assignmentID/preview-guide.json?as=<token>,
// the previewed student's guide with no attempt.
//
// A student is named in the URL by their opaque `urlToken`, as the staff
// submission pages do, so a username never reaches a request log (#556).

import Core
import Fluent
import Foundation
import Vapor

/// One student the workbench can preview.
struct WorkbenchPreviewStudent: Equatable {
    let userID: UUID
    /// The student's `urlToken`.
    let token: String
    /// The display name, else the username.
    let name: String
}

extension InstructorWorkbenchRoutes {

    /// The students enrolled in `courseID`, by name. Service accounts and
    /// staff are not students.
    static func previewStudents(courseID: UUID, on db: any Database) async throws -> [WorkbenchPreviewStudent] {
        let ids = try await CourseRoster.studentIDs(in: courseID, on: db)
        guard !ids.isEmpty else { return [] }
        let users = try await APIUser.query(on: db)
            .filter(\.$id ~~ Array(ids))
            .filter(\.$role != UserRole.mcp.rawValue)
            .all()
        return
            users
            .compactMap { user -> WorkbenchPreviewStudent? in
                // The token names a file and a JupyterLite workspace, so only
                // the alphabet `APIUser.generateURLToken` writes is accepted.
                guard let id = user.id, let token = user.urlToken, Self.isPreviewToken(token) else { return nil }
                let display = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return WorkbenchPreviewStudent(
                    userID: id, token: token, name: display.isEmpty ? user.username : display)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The student `token` names, or a 404 when no student of the course has
    /// it.
    static func previewStudent(
        token: String, courseID: UUID, on db: any Database
    ) async throws
        -> WorkbenchPreviewStudent
    {
        try previewStudent(token: token, in: try await previewStudents(courseID: courseID, on: db))
    }

    /// The student `token` names among `students`, or a 404.
    static func previewStudent(
        token: String, in students: [WorkbenchPreviewStudent]
    ) throws
        -> WorkbenchPreviewStudent
    {
        guard let student = students.first(where: { $0.token == token }) else {
            throw AppError.notFoundReason(reason: "No student of this course has that link.")
        }
        return student
    }

    /// True for a token of lowercase ASCII letters and digits.
    static func isPreviewToken(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    // MARK: - GET /instructor/:assignmentID/preview-guide.json

    @Sendable
    func previewGuide(req: Request) async throws -> Response {
        let (_, setup) = try await loadAssignmentAndSetupForStaffRead(req)
        guard let token = req.query[String.self, at: "as"] else {
            throw AppError.badRequest(reason: "Choose a student to preview.")
        }
        let student = try await Self.previewStudent(token: token, courseID: setup.courseID, on: req.db)
        let guide = try await WebRoutes().previewGuide(req: req, setup: setup, student: student)
        let response = Response(status: .ok)
        try response.content.encode(guide, as: .json)
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        return response
    }
}
