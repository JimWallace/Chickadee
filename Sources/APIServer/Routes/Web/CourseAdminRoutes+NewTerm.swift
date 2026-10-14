// APIServer/Routes/Web/CourseAdminRoutes+NewTerm.swift
//
// Instructor "New term" tab: clone the active course into a new offering
// (docs/course-terms.md slice 5).
//
//   GET  /instructor/new-term → InstructorNewTermPage (the clone form)
//   POST /instructor/new-term → clone, enroll the caller as instructor of the
//                               new course, switch to it, redirect with a flash
//
// The clone itself is `CourseCloneService`, the path the admin clone runs.
// Course creation is otherwise admin-only; an instructor may create a course
// only as a clone of one they teach, and becomes its instructor.

import Core
import Elementary
import Fluent
import Foundation
import Vapor

extension CourseAdminRoutes {
    @Sendable
    func newTermPage(req: Request) async throws -> HTMLResponse<InstructorNewTermPage> {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)

        var course: APICourse?
        if let courseUUID = courseState.activeCourseUUID {
            course = try await APICourse.find(courseUUID, on: req.db)
        }
        let canClone = user.isAdmin || (courseState.active?.role ?? .student) >= .instructor
        let next = course?.term?.next

        let justCloned = req.query[String.self, at: "cloned"] == "1"
        let errorCode = req.query[String.self, at: "error"]
        let flashError =
            errorCode == "course" ? "No active course." : CourseCloneFormError.message(forQuery: errorCode)

        let page = try await PageRequestContext.courseAware(req)
        return HTMLResponse {
            InstructorNewTermPage(
                page: page,
                flash: FlashMessages(
                    success: justCloned
                        ? "Cloned with enrollment closed; set the new course's dates before opening its assignments."
                        : nil,
                    error: flashError),
                hasActiveCourse: course != nil,
                courseCode: course?.code ?? "",
                courseName: course?.name ?? "",
                termLabel: course?.term?.displayName,
                canClone: canClone,
                justCloned: justCloned,
                cloneForm: CourseFieldsContext(
                    idPrefix: "new-term", code: course?.code ?? "", name: course?.name ?? "", term: next)
            )
        }
    }

    @Sendable
    func cloneActiveCourseForNewTerm(req: Request) async throws -> Response {
        struct CloneForm: Content {
            var code: String?
            var name: String?
            var termYear: String?
            var termSeason: String?
        }
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let sourceID = courseState.activeCourseUUID,
            let source = try await APICourse.find(sourceID, on: req.db)
        else {
            return req.redirect(to: "/instructor/new-term?error=course")
        }
        // Reading the source is enough authority to copy it, so an archived
        // source is allowed; the new course is written by the service, and
        // the per-course instructor floor is what makes that a lifecycle act.
        try await requireCourseRole(caller: user, courseID: sourceID, atLeast: .instructor, db: req.db)

        let form = try await req.decodeContent(CloneForm.self)
        let code = (form.code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (form.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !name.isEmpty else {
            return req.redirect(to: "/instructor/new-term?error=\(CourseCloneFormError.fields.rawValue)")
        }
        guard case .term(let term) = CourseTermInput(year: form.termYear, season: form.termSeason) else {
            return req.redirect(to: "/instructor/new-term?error=\(CourseCloneFormError.term.rawValue)")
        }
        if try await activeCourseCodeIsTaken(code, term: term, excluding: nil, on: req.db) {
            return req.redirect(to: "/instructor/new-term?error=\(CourseCloneFormError.codeTaken.rawValue)")
        }

        let userID = try user.requireID()
        let directories = AuthoringDirectories(
            setups: req.application.testSetupsDirectory,
            submissions: req.application.submissionsDirectory)
        let contentFilesDirectory = req.application.contentFilesDirectory
        let result = try await req.db.transaction { db in
            let result = try await CourseCloneService.clone(
                source: source, target: CourseCloneTarget(code: code, name: name, term: term),
                directories: directories, contentFilesDirectory: contentFilesDirectory, on: db)
            // The cloning instructor teaches the new course. Nobody else is
            // enrolled: staff and students join the new term afresh.
            try await APICourseEnrollment(
                userID: userID, courseID: try result.course.requireID(), role: .instructor
            ).save(on: db)
            return result
        }
        let newID = try result.course.requireID().uuidString
        await AuditLogger.record(
            action: .courseCloned, targetType: .course, targetID: newID,
            metadata: [
                "source_course_code": source.code,
                "course_code": code,
                "course_name": name,
                "course_term": term.displayName,
                "assignments": String(result.assignmentCount),
            ],
            on: req)
        req.session.data["activeCourseID"] = newID
        return req.redirect(to: "/instructor/new-term?cloned=1")
    }
}
