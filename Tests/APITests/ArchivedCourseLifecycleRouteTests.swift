// Tests/APITests/ArchivedCourseLifecycleRouteTests.swift
//
// Route-level coverage for the remaining per-course write gaps closed in #417
// Slice D: the assignment-lifecycle mutations (open/close/status/delete),
// drag-reorder, unpublished-setup delete, and the high-value TestSetupRoutes
// endpoints (upload + notebook save). Each now authorizes against the
// *resource's own* course via requireCourseWriteAccess, so a per-course
// instructor can neither mutate an archived course's content nor drive a write
// against another course by URL / by client-supplied courseID. The active-course
// group middleware only inspects the caller's active course, so this is the
// layer that catches it. Mirrors ArchivedCourseWriteRouteTests (Slice A) and
// ArchivedCourseStudentActionRouteTests (Slice C).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ArchivedCourseLifecycleRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-archived-lc")
    }

    /// Creates a course + worker-mode test setup + published assignment and
    /// returns the course UUID, setup ID, and the assignment's public ID.
    private func makeCourseAssignment(
        code: String, archived: Bool, enrollmentMode: CourseEnrollmentMode
    ) async throws -> (courseID: UUID, setupID: String, assignmentID: String) {
        let courseID = UUID()
        let course = APICourse(id: courseID, code: code, name: code, enrollmentMode: enrollmentMode)
        course.isArchived = archived
        try await course.save(on: app.db)

        let setupID = "lc_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try arMakeZip(at: zipPath, entries: [(".placeholder", "x"), ("publictest_a.py", "passed('a')\n")])
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_a.py"}],"timeLimitSeconds":10,"makefile":null}
            """
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)

        let assignment = APIAssignment(
            testSetupID: setupID, title: code,
            dueAt: nil, isOpen: true, deadlineOverrideActive: false, courseID: courseID
        )
        try await assignment.save(on: app.db)
        return (courseID, setupID, assignment.publicID)
    }

    /// The active + archived course fixtures plus the authenticated session for
    /// `lc_inst`. A struct rather than a tuple to stay within SwiftLint's
    /// `large_tuple` limit.
    private struct BothCoursesFixture {
        let active: (courseID: UUID, setupID: String, assignmentID: String)
        let archived: (courseID: UUID, setupID: String, assignmentID: String)
        let csrf: String
        let sessionCookie: String
    }

    /// Logs in `lc_inst` as an instructor in an active (.auto, non-archived)
    /// course and additionally enrols them as a per-course instructor in the
    /// given archived course, returning the session cookie + CSRF token and both
    /// fixtures. The active edit succeeding attributes any archived 403 to the
    /// archived block, not a stray middleware denial.
    private func setupInstructorWithBothCourses(
        activeCode: String, archivedCode: String
    ) async throws -> BothCoursesFixture {
        let active = try await makeCourseAssignment(
            code: activeCode, archived: false, enrollmentMode: .auto)
        let archived = try await makeCourseAssignment(
            code: archivedCode, archived: true, enrollmentMode: .closed)

        let cookie = try await loginUser(
            username: "lc_inst", password: "pw", role: "instructor", on: app)
        try await promoteToInstructor("lc_inst", on: app)  // active .auto course: promote (#417)
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "lc_inst").first())
        try await APICourseEnrollment(
            userID: try user.requireID(), courseID: archived.courseID, role: .instructor
        ).save(on: app.db)

        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return BothCoursesFixture(
            active: active, archived: archived, csrf: csrf, sessionCookie: sessionCookie)
    }

    private func postForm(_ path: String, csrf: String, sessionCookie: String) async throws -> HTTPStatus {
        var status: HTTPStatus = .imATeapot
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .urlEncodedForm
                req.body = ByteBuffer(string: "")
            },
            afterResponse: { res in status = res.status })
        return status
    }

    // MARK: - Assignment lifecycle (open / close / delete)

    @Test func closeBlockedOnArchivedCourseEvenForItsInstructor() async throws {
        try await withApp(app) { _ in
            let fx = try await setupInstructorWithBothCourses(activeCode: "LCAX", archivedCode: "LCAY")
            // Sanity: closing the active (non-archived) course's assignment works.
            let activeStatus = try await postForm(
                "/instructor/\(fx.active.assignmentID)/close", csrf: fx.csrf, sessionCookie: fx.sessionCookie)
            #expect(activeStatus == .seeOther, "active-course close should succeed, got \(activeStatus)")
            // The block: closing the archived course's assignment by URL is 403.
            let archivedStatus = try await postForm(
                "/instructor/\(fx.archived.assignmentID)/close", csrf: fx.csrf, sessionCookie: fx.sessionCookie)
            #expect(archivedStatus == .forbidden, "archived-course close must be blocked, got \(archivedStatus)")
        }
    }

    @Test func deleteBlockedOnArchivedCourseEvenForItsInstructor() async throws {
        try await withApp(app) { _ in
            let fx = try await setupInstructorWithBothCourses(activeCode: "LCBX", archivedCode: "LCBY")
            // The block: deleting the archived course's assignment by URL is 403.
            let archivedStatus = try await postForm(
                "/instructor/\(fx.archived.assignmentID)/delete", csrf: fx.csrf, sessionCookie: fx.sessionCookie)
            #expect(archivedStatus == .forbidden, "archived-course delete must be blocked, got \(archivedStatus)")
            // Sanity: deleting the active (non-archived) course's assignment works.
            let activeStatus = try await postForm(
                "/instructor/\(fx.active.assignmentID)/delete", csrf: fx.csrf, sessionCookie: fx.sessionCookie)
            #expect(activeStatus == .seeOther, "active-course delete should succeed, got \(activeStatus)")
        }
    }

    // MARK: - reorderAssignments — a foreign/archived course's assignment by ID

    @Test func reorderRejectsArchivedCourseAssignment() async throws {
        try await withApp(app) { _ in
            let fx = try await setupInstructorWithBothCourses(activeCode: "LCCX", archivedCode: "LCCY")
            // A reorder payload that includes the archived course's assignment ID
            // must be rejected — reordering writes sortOrder, a per-course write.
            try await app.asyncTest(
                .POST, "/instructor/reorder",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: fx.csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(
                        string: #"{"assignmentIDs":["\#(fx.archived.assignmentID)","\#(fx.active.assignmentID)"]}"#)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden,
                        "reorder touching an archived course must be blocked, got \(res.status)")
                })
        }
    }

    // MARK: - deleteUnpublishedSetup — a foreign/archived course's setup by ID

    @Test func deleteUnpublishedSetupBlockedOnArchivedCourse() async throws {
        try await withApp(app) { _ in
            let fx = try await setupInstructorWithBothCourses(activeCode: "LCDX", archivedCode: "LCDY")
            // Create an unpublished (assignment-less) setup in the archived course.
            let setupID = "lc_unpub_\(UUID().uuidString.prefix(8))"
            let zipPath = app.testSetupsDirectory + setupID + ".zip"
            try arMakeZip(at: zipPath, entries: [(".placeholder", "x")])
            let setup = APITestSetup(
                id: setupID,
                manifest:
                    #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#,
                zipPath: zipPath, courseID: fx.archived.courseID)
            try await setup.save(on: app.db)

            let status = try await postForm(
                "/instructor/setup/\(setupID)/delete", csrf: fx.csrf, sessionCookie: fx.sessionCookie)
            #expect(status == .forbidden, "deleting an archived course's setup must be blocked, got \(status)")
        }
    }

    // MARK: - TestSetupRoutes.saveAssignment (notebook overwrite) on archived course

    @Test func saveAssignmentNotebookBlockedOnArchivedCourse() async throws {
        try await withApp(app) { _ in
            let fx = try await setupInstructorWithBothCourses(activeCode: "LCEX", archivedCode: "LCEY")
            let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

            func putNotebook(setupID: String) async throws -> HTTPStatus {
                var status: HTTPStatus = .imATeapot
                try await app.asyncTest(
                    .PUT, "/api/v1/testsetups/\(setupID)/assignment",
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: fx.sessionCookie)
                        req.headers.add(name: "x-csrf-token", value: fx.csrf)
                        req.headers.contentType = .json
                        req.body = ByteBuffer(string: notebook)
                    },
                    afterResponse: { res in status = res.status })
                return status
            }

            // Sanity: saving to the active course's setup works.
            let activeStatus = try await putNotebook(setupID: fx.active.setupID)
            #expect(activeStatus == .noContent, "active-course notebook save should succeed, got \(activeStatus)")
            // The block: saving to the archived course's setup is 403.
            let archivedStatus = try await putNotebook(setupID: fx.archived.setupID)
            #expect(
                archivedStatus == .forbidden, "archived-course notebook save must be blocked, got \(archivedStatus)")
        }
    }

    // MARK: - TestSetupRoutes.uploadTestSetup — client-supplied foreign courseID

    @Test func uploadRejectsArchivedTargetCourse() async throws {
        try await withApp(app) { _ in
            let fx = try await setupInstructorWithBothCourses(activeCode: "LCFX", archivedCode: "LCFY")

            // A decodable upload whose courseID points at the archived course the
            // caller instructs must be rejected — the old global isInstructor check
            // trusted the client-supplied courseID. The manifest/files content is
            // irrelevant: the 403 fires before manifest/zip validation.
            let boundary = "LCUpload"
            let manifest =
                #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"t.sh"}],"timeLimitSeconds":10,"makefile":null}"#
            var body = ByteBufferAllocator().buffer(capacity: 512)
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"_csrf\"\r\n\r\n")
            body.writeString(fx.csrf)
            body.writeString("\r\n--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"manifest\"\r\n\r\n")
            body.writeString(manifest)
            body.writeString("\r\n--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"courseID\"\r\n\r\n")
            body.writeString(fx.archived.courseID.uuidString)
            body.writeString("\r\n--\(boundary)\r\n")
            body.writeString(
                "Content-Disposition: form-data; name=\"files\"; filename=\"setup.zip\"\r\n"
                    + "Content-Type: application/zip\r\n\r\n")
            body.writeString("PK")
            body.writeString("\r\n--\(boundary)--\r\n")

            try await app.asyncTest(
                .POST, "/api/v1/testsetups",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden,
                        "upload targeting an archived course must be blocked, got \(res.status)")
                })
        }
    }

    /// A zip-borne manifest pairing browser grading with grader-only files is
    /// refused at upload, like the upload-only + browser pair beside it: the
    /// browser path delivers the whole workspace to the student's kernel, so
    /// the marks could not be honored. The refusal fires during manifest
    /// validation, before the zip's own contents are checked.
    @Test func uploadRejectsGraderOnlyFilesWithBrowserGrading() async throws {
        try await withApp(app) { _ in
            let fx = try await setupInstructorWithBothCourses(activeCode: "LCGO", archivedCode: "LCGP")

            let boundary = "LCGraderOnly"
            let manifest =
                #"{"schemaVersion":1,"gradingMode":"browser","graderOnlyFiles":["answers.py"],"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#
            var body = ByteBufferAllocator().buffer(capacity: 512)
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"_csrf\"\r\n\r\n")
            body.writeString(fx.csrf)
            body.writeString("\r\n--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"manifest\"\r\n\r\n")
            body.writeString(manifest)
            body.writeString("\r\n--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"courseID\"\r\n\r\n")
            body.writeString(fx.active.courseID.uuidString)
            body.writeString("\r\n--\(boundary)\r\n")
            body.writeString(
                "Content-Disposition: form-data; name=\"files\"; filename=\"setup.zip\"\r\n"
                    + "Content-Type: application/zip\r\n\r\n")
            body.writeString("PK")
            body.writeString("\r\n--\(boundary)--\r\n")

            try await app.asyncTest(
                .POST, "/api/v1/testsetups",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .unprocessableEntity,
                        "grader-only + browser manifest must be rejected, got \(res.status)")
                    let bodyText = res.body.string
                    #expect(
                        bodyText.contains("grader-only"),
                        "rejection should carry the grader-only conflict message, got: \(bodyText)")
                })
        }
    }

    @Test func uploadRejectsUnparseableMinimumRunnerVersion() async throws {
        try await withApp(app) { _ in
            let fx = try await setupInstructorWithBothCourses(activeCode: "LCMV", archivedCode: "LCMW")

            // Auth passes for the active course, so manifest validation runs: an
            // unparseable minimumRunnerVersion gate is rejected (422) before the
            // zip is even written — mirroring the schemaVersion guard beside it.
            let boundary = "LCMinVer"
            let manifest =
                #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"t.sh"}],"timeLimitSeconds":10,"minimumRunnerVersion":"not-a-version","makefile":null}"#
            var body = ByteBufferAllocator().buffer(capacity: 512)
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"_csrf\"\r\n\r\n")
            body.writeString(fx.csrf)
            body.writeString("\r\n--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"manifest\"\r\n\r\n")
            body.writeString(manifest)
            body.writeString("\r\n--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"courseID\"\r\n\r\n")
            body.writeString(fx.active.courseID.uuidString)
            body.writeString("\r\n--\(boundary)\r\n")
            body.writeString(
                "Content-Disposition: form-data; name=\"files\"; filename=\"setup.zip\"\r\n"
                    + "Content-Type: application/zip\r\n\r\n")
            body.writeString("PK")
            body.writeString("\r\n--\(boundary)--\r\n")

            try await app.asyncTest(
                .POST, "/api/v1/testsetups",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .unprocessableEntity,
                        "unparseable minimumRunnerVersion must be rejected, got \(res.status)")
                })
        }
    }

    // MARK: - updateNewAssignmentDraft — a foreign/archived course's draft by draftID

    @Test func updateNewAssignmentDraftBlockedForArchivedCourseDraft() async throws {
        try await withApp(app) { _ in
            let fx = try await setupInstructorWithBothCourses(activeCode: "LCGX", archivedCode: "LCGY")

            // An (assignment-less) draft setup owned by the archived course.
            let draftID = "lc_draft_\(UUID().uuidString.prefix(8))"
            let zipPath = app.testSetupsDirectory + draftID + ".zip"
            try arMakeZip(at: zipPath, entries: [(".placeholder", "x")])
            let draft = APITestSetup(
                id: draftID,
                manifest:
                    #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#,
                zipPath: zipPath, courseID: fx.archived.courseID)
            try await draft.save(on: app.db)

            // Driving the primary draft-editor endpoint at the archived course's
            // draft by id must be rejected before the mutating service runs — the
            // resolver now authorizes the draft's own course.
            let boundary = "LCDraft"
            var body = ByteBufferAllocator().buffer(capacity: 512)
            for (name, value) in [
                ("_csrf", fx.csrf), ("assignmentName", "X"),
                ("draftAction", "create-assignment-notebook"), ("draftID", draftID),
            ] {
                body.writeString("--\(boundary)\r\n")
                body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                body.writeString(value)
                body.writeString("\r\n")
            }
            body.writeString("--\(boundary)--\r\n")

            try await app.asyncTest(
                .POST, "/instructor/new/draft",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden,
                        "editing an archived course's draft by draftID must be blocked, got \(res.status)")
                })
        }
    }
}
