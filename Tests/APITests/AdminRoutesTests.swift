import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation
import Core

final class AdminRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-admin-\(UUID().uuidString)/")
            .path

        let dirs = ["results/", "testsetups/", "submissions/"].map { tmpDir + $0 }
        for dir in dirs {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory = dirs[0]
        app.testSetupsDirectory = dirs[1]
        app.submissionsDirectory = dirs[2]
        app.workerSecretFilePath = tmpDir + ".worker-secret"
        app.localRunnerAutoStartFilePath = tmpDir + ".local-runner-autostart"

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateUsers())
        app.migrations.add(CreateCourses())
        app.migrations.add(CreateCourseEnrollments())
        app.migrations.add(CreateTestSetups())
        app.migrations.add(CreateSubmissions())
        app.migrations.add(CreateResults())
        app.migrations.add(CreateAssignments())
        app.migrations.add(CreatePerformanceIndexes())
        app.migrations.add(AddCourseSections())
        app.migrations.add(AddCourseOpenEnrollment())
        app.migrations.add(AddCourseEnrollmentMode())
        try await app.autoMigrate()

        configureLeaf(app)
        try routes(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func loginAsAdmin() async throws -> String {
        try await loginUser(username: "admin_routes", password: "testpassword", role: "admin", on: app)
    }

    private func csrfCookieAndToken(_ cookie: String, path: String = "/admin") async throws -> (String, String) {
        let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
        return (boundCookie, token)
    }

    @discardableResult
    private func makeCourse(
        code: String = "ADM101",
        name: String = "Admin Test Course",
        archived: Bool = false,
        mode: CourseEnrollmentMode = .open
    ) async throws -> APICourse {
        let course = APICourse(code: code, name: name, isArchived: archived, enrollmentMode: mode)
        try await course.save(on: app.db)
        return course
    }

    @discardableResult
    private func makeUser(username: String, role: String = "student") async throws -> APIUser {
        let user = APIUser(
            username: username,
            passwordHash: try Bcrypt.hash("pw"),
            role: role
        )
        try await user.save(on: app.db)
        return user
    }

    @discardableResult
    private func makeSetup(
        id: String,
        courseID: UUID,
        withNotebook: Bool = true
    ) async throws -> APITestSetup {
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
        """
        let zipPath = app.testSetupsDirectory + "\(id).zip"
        let notebookPath = app.testSetupsDirectory + "\(id).ipynb"
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
            .write(to: URL(fileURLWithPath: zipPath))
        if withNotebook {
            try #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
                .write(to: URL(fileURLWithPath: notebookPath), atomically: true, encoding: .utf8)
        }

        let setup = APITestSetup(
            id: id,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: withNotebook ? notebookPath : nil,
            courseID: courseID
        )
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func makeAssignment(
        testSetupID: String,
        courseID: UUID,
        title: String = "Admin Lab"
    ) async throws -> APIAssignment {
        let assignment = APIAssignment(
            testSetupID: testSetupID,
            title: title,
            dueAt: nil,
            isOpen: true,
            courseID: courseID
        )
        try await assignment.save(on: app.db)
        return assignment
    }

    @discardableResult
    private func makeEnrollment(userID: UUID, courseID: UUID) async throws -> APICourseEnrollment {
        let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
        try await enrollment.save(on: app.db)
        return enrollment
    }

    @discardableResult
    private func makeSubmission(
        id: String,
        setupID: String,
        userID: UUID
    ) async throws -> APISubmission {
        let path = app.submissionsDirectory + "\(id).ipynb"
        try #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
            .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        let submission = APISubmission(
            id: id,
            testSetupID: setupID,
            zipPath: path,
            attemptNumber: 1,
            status: "complete",
            filename: "\(id).ipynb",
            userID: userID,
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: app.db)
        return submission
    }

    @discardableResult
    private func makeResult(submissionID: String) async throws -> APIResult {
        let result = APIResult(
            id: "res_\(UUID().uuidString.lowercased().prefix(8))",
            submissionID: submissionID,
            collectionJSON: #"{"submissionID":"\#(submissionID)","outcomes":[]}"#,
            source: "worker"
        )
        try await result.save(on: app.db)
        return result
    }

    func testChangeRoleUpdatesUserRole() async throws {
        let cookie = try await loginAsAdmin()
        let target = try await makeUser(username: "role_target", role: "student")
        let userID = try target.requireID()
        let (boundCookie, token) = try await csrfCookieAndToken(cookie)

        try await app.asyncTest(.POST, "/admin/users/\(userID.uuidString)/role", beforeRequest: { req in
            req.headers.add(name: .cookie, value: boundCookie)
            try req.content.encode(["role": "instructor", "_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin")
        })

        let updated = try await APIUser.find(userID, on: app.db)
        XCTAssertEqual(updated?.role, "instructor")
    }

    func testUpdateWorkerSecretPersistsRuntimeOverride() async throws {
        let cookie = try await loginAsAdmin()
        let (boundCookie, token) = try await csrfCookieAndToken(cookie)

        try await app.asyncTest(.POST, "/admin/runner-secret", beforeRequest: { req in
            req.headers.add(name: .cookie, value: boundCookie)
            try req.content.encode(["secret": " new-runner-secret ", "_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin")
        })

        let runtime = await app.workerSecretStore.runtimeOverrideValue()
        XCTAssertEqual(runtime, "new-runner-secret")
        XCTAssertEqual(
            readWorkerSecretFromDisk(workerSecretFilePath: app.workerSecretFilePath),
            "new-runner-secret"
        )
    }

    func testUpdateWorkerSecretBlankRestoresPersistedValue() async throws {
        let cookie = try await loginAsAdmin()
        writeWorkerSecretToDisk(secret: "persisted-secret", workerSecretFilePath: app.workerSecretFilePath)
        await app.workerSecretStore.setRuntimeOverride("runtime-secret")
        let (boundCookie, token) = try await csrfCookieAndToken(cookie)

        try await app.asyncTest(.POST, "/admin/runner-secret", beforeRequest: { req in
            req.headers.add(name: .cookie, value: boundCookie)
            try req.content.encode(["secret": "   ", "_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let runtime = await app.workerSecretStore.runtimeOverrideValue()
        XCTAssertEqual(runtime, "persisted-secret")
    }

    func testUpdateLocalRunnerAutoStartPersistsSetting() async throws {
        let cookie = try await loginAsAdmin()
        let (boundCookie, token) = try await csrfCookieAndToken(cookie)

        try await app.asyncTest(.POST, "/admin/runner-autostart", beforeRequest: { req in
            req.headers.add(name: .cookie, value: boundCookie)
            req.body = .init(string: "localRunnerAutoStart=on&_csrf=\(token)")
            req.headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin")
        })

        let isEnabled = await app.localRunnerAutoStartStore.isEnabled()
        XCTAssertTrue(isEnabled)
        XCTAssertEqual(readLocalRunnerAutoStartFromDisk(filePath: app.localRunnerAutoStartFilePath), true)
    }

    func testEditCourseUpdatesFields() async throws {
        let cookie = try await loginAsAdmin()
        let course = try await makeCourse(code: "EDIT101", name: "Original Name")
        let courseID = try course.requireID()
        let (boundCookie, token) = try await csrfCookieAndToken(cookie, path: "/admin/courses/\(courseID.uuidString)")

        try await app.asyncTest(.POST, "/admin/courses/\(courseID.uuidString)/edit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: boundCookie)
            try req.content.encode(
                ["code": "EDIT201", "name": "Updated Name", "_csrf": token],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin/courses/\(courseID.uuidString)")
        })

        let updated = try await APICourse.find(courseID, on: app.db)
        XCTAssertEqual(updated?.code, "EDIT201")
        XCTAssertEqual(updated?.name, "Updated Name")
    }

    func testToggleCourseArchiveFlipsArchivedState() async throws {
        let cookie = try await loginAsAdmin()
        let course = try await makeCourse(code: "ARCH101", name: "Archive Me", archived: false)
        let courseID = try course.requireID()
        let (boundCookie, token) = try await csrfCookieAndToken(cookie, path: "/admin/courses/\(courseID.uuidString)")

        try await app.asyncTest(.POST, "/admin/courses/\(courseID.uuidString)/archive", beforeRequest: { req in
            req.headers.add(name: .cookie, value: boundCookie)
            try req.content.encode(["_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let updated = try await APICourse.find(courseID, on: app.db)
        XCTAssertEqual(updated?.isArchived, true)
    }

    func testDeleteCourseRemovesRecordsAndFilesForArchivedCourse() async throws {
        let cookie = try await loginAsAdmin()
        let student = try await makeUser(username: "delete_student", role: "student")
        let studentID = try student.requireID()
        let course = try await makeCourse(code: "DEL101", name: "Delete Me", archived: true)
        let courseID = try course.requireID()
        let setup = try await makeSetup(id: "setup_delete_admin", courseID: courseID)
        _ = try await makeAssignment(testSetupID: "setup_delete_admin", courseID: courseID)
        _ = try await makeEnrollment(userID: studentID, courseID: courseID)
        let submission = try await makeSubmission(id: "sub_delete_admin", setupID: "setup_delete_admin", userID: studentID)
        _ = try await makeResult(submissionID: try submission.requireID())
        let (boundCookie, token) = try await csrfCookieAndToken(cookie, path: "/admin/courses/\(courseID.uuidString)")

        try await app.asyncTest(.POST, "/admin/courses/\(courseID.uuidString)/delete", beforeRequest: { req in
            req.headers.add(name: .cookie, value: boundCookie)
            try req.content.encode(["_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin")
        })

        let deletedCourse = try await APICourse.find(courseID, on: app.db)
        let assignmentCount = try await APIAssignment.query(on: app.db).filter(\.$courseID == courseID).count()
        let setupCount = try await APITestSetup.query(on: app.db).filter(\.$courseID == courseID).count()
        let enrollmentCount = try await APICourseEnrollment.query(on: app.db).filter(\.$course.$id == courseID).count()
        let submissionCount = try await APISubmission.query(on: app.db).filter(\.$testSetupID == "setup_delete_admin").count()
        let resultCount = try await APIResult.query(on: app.db).count()
        XCTAssertNil(deletedCourse)
        XCTAssertEqual(assignmentCount, 0)
        XCTAssertEqual(setupCount, 0)
        XCTAssertEqual(enrollmentCount, 0)
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(resultCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.testSetupsDirectory + "setup_delete_admin.zip"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.testSetupsDirectory + "setup_delete_admin.ipynb"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: submission.zipPath))
        _ = setup
    }

    func testAdminEnrollAndUnenrollUserMutatesEnrollment() async throws {
        let cookie = try await loginAsAdmin()
        let user = try await makeUser(username: "managed_student", role: "student")
        let userID = try user.requireID()
        let course = try await makeCourse(code: "ENROLL101", name: "Managed Course")
        let courseID = try course.requireID()

        let (enrollCookie, enrollToken) = try await csrfCookieAndToken(cookie, path: "/admin/users/\(userID.uuidString)")
        try await app.asyncTest(.POST, "/admin/users/\(userID.uuidString)/enroll", beforeRequest: { req in
            req.headers.add(name: .cookie, value: enrollCookie)
            try req.content.encode(
                ["courseID": courseID.uuidString, "_csrf": enrollToken],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin/users/\(userID.uuidString)")
        })

        let enrollmentCountAfterEnroll = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count()
        XCTAssertEqual(enrollmentCountAfterEnroll, 1)

        let (unenrollCookie, unenrollToken) = try await csrfCookieAndToken(cookie, path: "/admin/users/\(userID.uuidString)")
        try await app.asyncTest(.POST, "/admin/users/\(userID.uuidString)/unenroll/\(courseID.uuidString)", beforeRequest: { req in
            req.headers.add(name: .cookie, value: unenrollCookie)
            try req.content.encode(["_csrf": unenrollToken], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin/users/\(userID.uuidString)")
        })

        let enrollmentCountAfterUnenroll = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count()
        XCTAssertEqual(enrollmentCountAfterUnenroll, 0)
    }
}
