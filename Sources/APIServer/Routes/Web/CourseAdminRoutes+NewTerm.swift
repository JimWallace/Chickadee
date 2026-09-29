// APIServer/Routes/Web/CourseAdminRoutes+NewTerm.swift
//
// Instructor "New term" tab: clone the active course into a new offering
// (docs/course-terms.md slice 5).
//
//   GET  /instructor/new-term → instructor-new-term.leaf (the clone form)
//   POST /instructor/new-term → clone, enroll the caller as instructor of the
//                               new course, switch to it, redirect with a flash
//
// The clone itself is `CourseCloneService`, the path the admin clone runs.
// Course creation is otherwise admin-only; an instructor may create a course
// only as a clone of one they teach, and becomes its instructor.

import Core
import Fluent
import Foundation
import Vapor

extension CourseAdminRoutes {
    @Sendable
    func newTermPage(req: Request) async throws -> View {
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

        let ctx = InstructorNewTermContext(
            currentUser: try await req.courseAwareUserContext(),
            activeInstructorTab: "new-term",
            hasActiveCourse: course != nil,
            courseCode: course?.code ?? "",
            courseName: course?.name ?? "",
            termLabel: course?.term?.displayName,
            canClone: canClone,
            justCloned: justCloned,
            cloneYear: next?.year,
            cloneTermOptions: CourseTermForm.options(selected: next?.season),
            flashSuccess: justCloned ? "Cloned; set the new course's dates before opening its assignments." : nil,
            flashError: flashError)
        return try await req.view.render("instructor-new-term", ctx)
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

        let form = try req.content.decode(CloneForm.self)
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

struct InstructorNewTermContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let hasActiveCourse: Bool
    let courseCode: String
    let courseName: String
    /// "Fall 2026", or nil when the active course records no term.
    let termLabel: String?
    /// True for a per-course instructor or an admin. A TA sees the tab but
    /// not the form: creating a course is a lifecycle act.
    let canClone: Bool
    /// True on the page shown right after a clone: the active course is now
    /// the new one, so the page points to its assignments, not to a second
    /// clone.
    let justCloned: Bool
    /// The form defaults: the term after the active course's.
    let cloneYear: Int?
    let cloneTermOptions: [CourseTermOption]
    let flashSuccess: String?
    let flashError: String?
}
