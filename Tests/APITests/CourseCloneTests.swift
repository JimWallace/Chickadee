// Tests/APITests/CourseCloneTests.swift
//
// Slice 4 of docs/course-terms.md: an admin clones a course into a new term.
// Content and settings come along; people, their work and the outside
// bindings stay with the source; every copied assignment starts closed, with
// no dates and its solution hidden.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(10))) final class CourseCloneTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-course-clone")
    }

    private func postClone(
        _ sourceID: UUID, form: [String: String], cookie: String
    ) async throws -> String? {
        let path = "/admin/courses/\(sourceID.uuidString)"
        let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
        var fields = form
        fields["_csrf"] = token
        var location: String?
        try await app.asyncTest(
            .POST, path + "/clone",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(fields, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location)
            })
        return location
    }

    /// A Fall 2026 course with two sections, two assignments (one with a
    /// due date, the "after due" solution reveal and a passing threshold),
    /// a content item with an attachment file, custom settings, an enrolled
    /// student and a submission.
    private func makeSource() async throws -> (course: APICourse, attachmentID: UUID) {
        let course = APICourse(
            code: "CL135", name: "Clone Source", enrollmentMode: .closed,
            term: AcademicTerm(year: 2026, season: .fall))
        course.slipDaysEnabled = true
        course.slipDaysPerStudent = 3
        course.mcpInstructions = "Write in the passive voice."
        course.brightspaceOrgUnitID = "12345"
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let labs = APICourseSection(name: "Labs", defaultGradingMode: "browser", sortOrder: 1, courseID: courseID)
        try await labs.save(on: app.db)
        let exams = APICourseSection(name: "Exams", defaultGradingMode: "worker", sortOrder: 2, courseID: courseID)
        try await exams.save(on: app.db)

        try await makeTestSetup(on: app, id: "setup_clsrc1", courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_clsrc2", courseID: courseID)
        let lab = try await makeTestAssignment(
            on: app, testSetupID: "setup_clsrc1", courseID: courseID, title: "Lab 1",
            dueAt: Date(timeIntervalSince1970: 1_790_000_000))
        lab.sectionID = try labs.requireID()
        lab.sortOrder = 5
        // Every date and deadline field is set on the source, so each reset the
        // clone makes is asserted against a value, not against a nil that was
        // nil already (#1785).
        lab.startsAt = Date(timeIntervalSince1970: 1_789_000_000)
        lab.deadlineOverrideActive = true
        lab.solutionVisibilityRaw = SolutionVisibility.afterDue.rawValue
        lab.passingThresholdPercent = 60
        lab.brightspaceGradeObjectID = "999"
        try await lab.save(on: app.db)
        let exam = try await makeTestAssignment(
            on: app, testSetupID: "setup_clsrc2", courseID: courseID, title: "Exam")
        exam.sectionID = try exams.requireID()
        exam.sortOrder = 6
        try await exam.save(on: app.db)

        let attachmentID = UUID()
        let item = APICourseContentItem(
            id: UUID(), courseID: courseID, sectionID: try labs.requireID(), sortOrder: 1,
            title: "Syllabus", kind: .link,
            attachments: [ContentAttachment(id: attachmentID, originalName: "syllabus.pdf", sizeBytes: 4, sortOrder: 0)]
        )
        let itemDir = app.contentFilesDirectory + (try #require(item.id)).uuidString + "/"
        try FileManager.default.createDirectory(atPath: itemDir, withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: URL(fileURLWithPath: itemDir + attachmentID.uuidString))
        try await item.save(on: app.db)

        let student = try await makeTestUser(on: app, username: "clone_student")
        try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: courseID)
        try await makeTestSubmission(
            on: app, id: "sub_clsrc1", setupID: "setup_clsrc1", userID: student.requireID())
        return (course, attachmentID)
    }

    @Test func cloneCopiesContentIntoTheNewTerm() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("clone_admin", on: app)
            let (source, attachmentID) = try await makeSource()
            let sourceID = try source.requireID()

            let location = try await postClone(
                sourceID,
                form: ["code": "CL135", "name": "Clone Target", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie)

            let clone = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "CL135").filter(\.$id != sourceID).first())
            let cloneID = try clone.requireID()
            #expect(location == "/admin/courses/\(cloneID.uuidString)")
            #expect(clone.term == AcademicTerm(year: 2027, season: .winter))
            #expect(clone.name == "Clone Target")

            // Settings come along; the LMS binding does not.
            #expect(clone.enrollmentMode == .closed)
            #expect(clone.slipDaysEnabled == true)
            #expect(clone.slipDaysPerStudent == 3)
            #expect(clone.mcpInstructions == "Write in the passive voice.")
            #expect(clone.brightspaceOrgUnitID == nil)

            let sections = try await APICourseSection.query(on: app.db)
                .filter(\.$courseID == cloneID).sort(\.$sortOrder).all()
            #expect(sections.map(\.name) == ["Labs", "Exams"])

            let assignments = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == cloneID).sort(\.$sortOrder).all()
            #expect(assignments.map(\.title) == ["Lab 1", "Exam"])
            #expect(assignments.map(\.sortOrder) == [5, 6])
            #expect(assignments.map(\.sectionID) == sections.map(\.id))
            let lab = try #require(assignments.first)
            #expect(lab.visibility == .closed)
            #expect(lab.validationStatus == nil)
            #expect(lab.dueAt == nil)
            #expect(lab.startsAt == nil)
            #expect(lab.deadlineOverrideActive != true)
            #expect(lab.solutionVisibilityRaw == nil)
            #expect(lab.passingThresholdPercent == 60)
            #expect(lab.brightspaceGradeObjectID == nil)
            #expect(lab.testSetupID != "setup_clsrc1")
            let setupCount = try await APITestSetup.query(on: app.db).filter(\.$courseID == cloneID).count()
            #expect(setupCount == 2)

            // The content item and its file are copied under a new item id.
            let item = try #require(
                try await APICourseContentItem.query(on: app.db).filter(\.$courseID == cloneID).first())
            #expect(item.title == "Syllabus")
            #expect(item.sectionID == sections.first?.id)
            #expect(item.attachments.map(\.id) == [attachmentID])
            let copiedFile =
                app.contentFilesDirectory + (try #require(item.id)).uuidString + "/"
                + attachmentID.uuidString
            #expect(FileManager.default.fileExists(atPath: copiedFile))

            // People and their work stay with the source.
            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == cloneID).count()
            #expect(enrollments == 0)
            let cloneSetupIDs = assignments.map(\.testSetupID)
            let studentSubmissions = try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID ~~ cloneSetupIDs)
                .filter(\.$kind == APISubmission.Kind.student)
                .count()
            #expect(studentSubmissions == 0)

            // The source is untouched.
            let sourceAssignments = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == sourceID).count()
            #expect(sourceAssignments == 2)
            let sourceAfter = try #require(try await APICourse.find(sourceID, on: app.db))
            #expect(sourceAfter.isArchived == false)

            // The clone is recorded.
            let audited = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.courseCloned.rawValue)
                .filter(\.$targetID == cloneID.uuidString)
                .count()
            #expect(audited == 1)
        }
    }

    @Test(arguments: [
        (["code": "", "name": "X", "termYear": "2027", "termSeason": "winter"], "clone_fields_required"),
        (["code": "CL200", "name": "X", "termYear": "27", "termSeason": "winter"], "clone_term_required"),
        (["code": "CL200", "name": "X"], "clone_term_required"),
        (["code": "CL200", "name": "X", "termYear": "2026", "termSeason": "fall"], "clone_code_taken"),
    ])
    func cloneRefusesAnInvalidForm(form: [String: String], error: String) async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("clone_admin", on: app)
            let source = APICourse(code: "CL200", name: "Source", term: AcademicTerm(year: 2026, season: .fall))
            try await source.save(on: app.db)
            let sourceID = try source.requireID()

            let location = try await postClone(sourceID, form: form, cookie: cookie)
            #expect(location == "/admin/courses/\(sourceID.uuidString)?error=\(error)#clone-course")
            let count = try await APICourse.query(on: app.db).count()
            #expect(count == 1)
        }
    }

    @Test func coursePageOffersTheNextTermToCloneInto() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("clone_admin", on: app)
            let source = APICourse(code: "CL300", name: "Source", term: AcademicTerm(year: 2026, season: .fall))
            try await source.save(on: app.db)
            var html = ""
            try await app.asyncTest(
                .GET, "/admin/courses/\(try source.requireID().uuidString)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in html = res.body.string })
            let form = try #require(
                html.range(of: "action=\"/admin/courses/\(try source.requireID().uuidString)/clone\""))
            let cloneForm = String(html[form.lowerBound...])
            #expect(cloneForm.contains("value=\"2027\""))
            #expect(cloneForm.contains("<option value=\"winter\" selected"))

            // The courses table links to the form. The fragment follows a Leaf
            // interpolation, so check that it renders as literal text.
            var admin = ""
            try await app.asyncTest(
                .GET, "/admin",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in admin = res.body.string })
            #expect(admin.contains("href=\"/admin/courses/\(try source.requireID().uuidString)#clone-course\""))
        }
    }

    /// The one-click copy keeps its `-COPY` naming, and now its term too, so
    /// it lands in the same term as a sandbox beside the source.
    @Test func oneClickCopyKeepsTheSourceTerm() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("clone_admin", on: app)
            let source = APICourse(code: "CL400", name: "Source", term: AcademicTerm(year: 2026, season: .fall))
            try await source.save(on: app.db)
            let path = "/admin/courses/\(try source.requireID().uuidString)"
            let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, path + "/copy",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            let copy = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "CL400-COPY").first())
            #expect(copy.term == AcademicTerm(year: 2026, season: .fall))
        }
    }

    /// A clone starts with enrollment closed, whatever the source's mode. An
    /// `.auto` mode copied across would enroll every user who logs in, last
    /// term's students included, before the instructor sets up the new term
    /// (#1780).
    @Test(arguments: [CourseEnrollmentMode.auto, .open])
    func aCloneStartsWithEnrollmentClosed(sourceMode: CourseEnrollmentMode) async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("clone_admin", on: app)
            let source = APICourse(
                code: "CL500", name: "Source", enrollmentMode: sourceMode,
                term: AcademicTerm(year: 2026, season: .fall))
            try await source.save(on: app.db)
            let sourceID = try source.requireID()

            _ = try await postClone(
                sourceID,
                form: ["code": "CL500", "name": "Target", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie)
            let clone = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "CL500").filter(\.$id != sourceID).first())
            #expect(clone.enrollmentMode == .closed)

            // A student who logs in after the clone joins the source if it is
            // `.auto`, and never the clone.
            try await loginUser(username: "clone_late_student", password: "testpassword", role: "user", on: app)
            let student = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "clone_late_student").first())
            let courseIDs = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == student.requireID())
                .all()
                .map { $0.$course.id }
            #expect(!courseIDs.contains(try clone.requireID()))
            #expect(courseIDs.contains(sourceID) == (sourceMode == .auto))
        }
    }
}
