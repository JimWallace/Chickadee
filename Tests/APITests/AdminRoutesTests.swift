import Core
import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class AdminRoutesTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-admin")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
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

        try await app.asyncTest(
            .POST, "/admin/users/\(userID.uuidString)/role",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(["role": "instructor", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/admin")
            })

        let updated = try await APIUser.find(userID, on: app.db)
        XCTAssertEqual(updated?.role, "instructor")
    }

    func testUpdateWorkerSecretPersistsRuntimeOverride() async throws {
        let cookie = try await loginAsAdmin()
        let (boundCookie, token) = try await csrfCookieAndToken(cookie)

        try await app.asyncTest(
            .POST, "/admin/runner-secret",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(["secret": " new-runner-secret ", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
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

    func testWriteWorkerSecretToDiskSetsOwnerOnlyPermissions() throws {
        // The worker secret is the HMAC signing key for runner↔server
        // requests; default umask leaves it world-readable on Linux, so
        // writeWorkerSecretToDisk must enforce 0o600.
        let path = app.workerSecretFilePath
        writeWorkerSecretToDisk(secret: "mode-check-secret", workerSecretFilePath: path)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(
            perms & 0o777, 0o600,
            "Expected .worker-secret to be 0600; got \(String(perms, radix: 8))")
    }

    func testReadWorkerSecretFromDiskTightensExistingPermissions() throws {
        // Files written by older builds may be world-readable; read-time
        // hardening ensures upgraded installs converge on 0o600.
        let path = app.workerSecretFilePath
        try "legacy-secret".write(
            toFile: path, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: path
        )

        _ = readWorkerSecretFromDisk(workerSecretFilePath: path)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600)
    }

    func testUpdateWorkerSecretBlankRestoresPersistedValue() async throws {
        let cookie = try await loginAsAdmin()
        writeWorkerSecretToDisk(secret: "persisted-secret", workerSecretFilePath: app.workerSecretFilePath)
        await app.workerSecretStore.setRuntimeOverride("runtime-secret")
        let (boundCookie, token) = try await csrfCookieAndToken(cookie)

        try await app.asyncTest(
            .POST, "/admin/runner-secret",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(["secret": "   ", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
            })

        let runtime = await app.workerSecretStore.runtimeOverrideValue()
        XCTAssertEqual(runtime, "persisted-secret")
    }

    func testUpdateLocalRunnerAutoStartPersistsSetting() async throws {
        let cookie = try await loginAsAdmin()
        let (boundCookie, token) = try await csrfCookieAndToken(cookie)

        try await app.asyncTest(
            .POST, "/admin/runner-autostart",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                req.body = .init(string: "localRunnerAutoStart=on&_csrf=\(token)")
                req.headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/admin")
            })

        let isEnabled = await app.localRunnerAutoStartStore.isEnabled()
        XCTAssertTrue(isEnabled)
        XCTAssertEqual(readLocalRunnerAutoStartFromDisk(filePath: app.localRunnerAutoStartFilePath), true)
    }

    func testAdminDashboardShowsJobsProcessedCardLabel() async throws {
        let cookie = try await loginAsAdmin()

        try await app.asyncTest(
            .GET, "/admin",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("24h Jobs Processed"))
                XCTAssertFalse(body.contains("24h Peak Util"))
            })
    }

    func testAdminDashboardDefaultsUsersToMostRecentLastSeenFirst() async throws {
        let cookie = try await loginAsAdmin()
        let now = Date()
        _ = try await makeUser(username: "never_seen")
        let older = try await makeUser(username: "older_seen", role: "student")
        older.lastSeenAt = now.addingTimeInterval(-3600)
        try await older.save(on: app.db)
        let recent = try await makeUser(username: "recent_seen", role: "student")
        recent.lastSeenAt = now
        try await recent.save(on: app.db)

        try await app.asyncTest(
            .GET, "/admin",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("data-sort-key=\"last-seen\""))
                XCTAssertTrue(body.contains("sortUsersByHeader(defaultUserHeader, 'desc');"))
                let recentIndex = try XCTUnwrap(body.range(of: "recent_seen")?.lowerBound)
                let olderIndex = try XCTUnwrap(body.range(of: "older_seen")?.lowerBound)
                let neverIndex = try XCTUnwrap(body.range(of: "never_seen")?.lowerBound)
                XCTAssertLessThan(recentIndex, olderIndex)
                XCTAssertLessThan(olderIndex, neverIndex)
            })
    }

    // MARK: - POST /admin/users/:userID/delete — FK cleanup (#562)

    /// Deleting a user must CASCADE-delete the `class_achievements` rows
    /// that reference them.  The DB-level FK constraint added by
    /// `AddUserFKConstraints` covers Postgres; the admin handler enforces
    /// the same semantics in application code so SQLite (which can't add
    /// FK constraints to existing columns) behaves identically.
    func testDeleteUserCascadesClassAchievements() async throws {
        let cookie = try await loginAsAdmin()
        let student = try await makeUser(username: "fk_cascade_student", role: "student")
        let studentID = try student.requireID()
        let course = try await makeCourse(code: "FKC101", name: "FK Cascade")
        let courseID = try course.requireID()
        let setup = try await makeSetup(id: "fk_cascade_setup", courseID: courseID)
        _ = setup
        let submission = try await makeSubmission(
            id: "fk_cascade_sub", setupID: "fk_cascade_setup", userID: studentID)

        let achievement = APIClassAchievement(
            testSetupID: "fk_cascade_setup",
            achievementID: "speed_champion",
            userID: studentID,
            submissionID: try submission.requireID(),
            metricValue: 42
        )
        try await achievement.save(on: app.db)
        let preDeleteCount = try await APIClassAchievement.query(on: app.db)
            .filter(\.$userID == studentID)
            .count()
        XCTAssertEqual(preDeleteCount, 1)

        let (boundCookie, token) = try await csrfCookieAndToken(cookie)
        try await app.asyncTest(
            .POST, "/admin/users/\(studentID.uuidString)/delete",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
            }
        )

        let reloadedUser = try await APIUser.find(studentID, on: app.db)
        XCTAssertNil(reloadedUser)
        let postDeleteCount = try await APIClassAchievement.query(on: app.db)
            .filter(\.$userID == studentID)
            .count()
        XCTAssertEqual(
            postDeleteCount, 0,
            "class_achievements rows referencing the deleted user must be removed")
    }

    /// Deleting an instructor who has retested submissions must NULL out
    /// `submissions.retested_by_user_id` — the submission row stays
    /// (immutable grade history) but the retest attribution drops.
    func testDeleteUserNullsRetestedByReferences() async throws {
        let cookie = try await loginAsAdmin()
        let student = try await makeUser(username: "fk_null_student", role: "student")
        let studentID = try student.requireID()
        let instructor = try await makeUser(username: "fk_null_instructor", role: "instructor")
        let instructorID = try instructor.requireID()
        let course = try await makeCourse(code: "FKN101", name: "FK Null")
        let courseID = try course.requireID()
        _ = try await makeSetup(id: "fk_null_setup", courseID: courseID)
        let submission = try await makeSubmission(
            id: "fk_null_sub", setupID: "fk_null_setup", userID: studentID)
        submission.retestedByUserID = instructorID
        try await submission.save(on: app.db)

        let (boundCookie, token) = try await csrfCookieAndToken(cookie)
        try await app.asyncTest(
            .POST, "/admin/users/\(instructorID.uuidString)/delete",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
            }
        )

        let reloadedInstructor = try await APIUser.find(instructorID, on: app.db)
        XCTAssertNil(reloadedInstructor)
        let reloaded = try await APISubmission.find("fk_null_sub", on: app.db)
        XCTAssertNotNil(reloaded, "Submission row must be preserved as immutable grade history")
        XCTAssertNil(
            reloaded?.retestedByUserID,
            "retested_by_user_id must clear when the referenced user is deleted")
    }

    func testAdminUserActionsRenderDeleteInUsersTableOnly() async throws {
        let cookie = try await loginAsAdmin()
        let managedUser = try await makeUser(username: "managed_for_actions", role: "student")
        let userID = try managedUser.requireID()

        try await app.asyncTest(
            .GET, "/admin",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("<th>Actions</th>"))
                XCTAssertFalse(body.contains("<th>Courses</th>"))
                XCTAssertTrue(body.contains("/admin/users/\(userID.uuidString)/delete"))
                XCTAssertTrue(body.contains("aria-label=\"Delete user\""))
            })

        try await app.asyncTest(
            .GET, "/admin/users/\(userID.uuidString)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertFalse(body.contains(">Delete User<"))
                XCTAssertFalse(body.contains("/admin/users/\(userID.uuidString)/delete"))
            })
    }

    func testEditCourseUpdatesFields() async throws {
        let cookie = try await loginAsAdmin()
        let course = try await makeCourse(code: "EDIT101", name: "Original Name")
        let courseID = try course.requireID()
        let (boundCookie, token) = try await csrfCookieAndToken(cookie, path: "/admin/courses/\(courseID.uuidString)")

        try await app.asyncTest(
            .POST, "/admin/courses/\(courseID.uuidString)/edit",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(
                    ["code": "EDIT201", "name": "Updated Name", "_csrf": token],
                    as: .urlEncodedForm
                )
            },
            afterResponse: { res in
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

        try await app.asyncTest(
            .POST, "/admin/courses/\(courseID.uuidString)/archive",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
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
        let submission = try await makeSubmission(
            id: "sub_delete_admin", setupID: "setup_delete_admin", userID: studentID)
        _ = try await makeResult(submissionID: try submission.requireID())
        let (boundCookie, token) = try await csrfCookieAndToken(cookie, path: "/admin/courses/\(courseID.uuidString)")

        try await app.asyncTest(
            .POST, "/admin/courses/\(courseID.uuidString)/delete",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/admin")
            })

        let deletedCourse = try await APICourse.find(courseID, on: app.db)
        let assignmentCount = try await APIAssignment.query(on: app.db).filter(\.$courseID == courseID).count()
        let setupCount = try await APITestSetup.query(on: app.db).filter(\.$courseID == courseID).count()
        let enrollmentCount = try await APICourseEnrollment.query(on: app.db).filter(\.$course.$id == courseID).count()
        let submissionCount = try await APISubmission.query(on: app.db).filter(\.$testSetupID == "setup_delete_admin")
            .count()
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

        let (enrollCookie, enrollToken) = try await csrfCookieAndToken(
            cookie, path: "/admin/users/\(userID.uuidString)")
        try await app.asyncTest(
            .POST, "/admin/users/\(userID.uuidString)/enroll",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: enrollCookie)
                try req.content.encode(
                    ["courseID": courseID.uuidString, "_csrf": enrollToken],
                    as: .urlEncodedForm
                )
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/admin/users/\(userID.uuidString)")
            })

        let enrollmentCountAfterEnroll = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count()
        XCTAssertEqual(enrollmentCountAfterEnroll, 1)

        let (unenrollCookie, unenrollToken) = try await csrfCookieAndToken(
            cookie, path: "/admin/users/\(userID.uuidString)")
        try await app.asyncTest(
            .POST, "/admin/users/\(userID.uuidString)/unenroll/\(courseID.uuidString)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: unenrollCookie)
                try req.content.encode(["_csrf": unenrollToken], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/admin/users/\(userID.uuidString)")
            })

        let enrollmentCountAfterUnenroll = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count()
        XCTAssertEqual(enrollmentCountAfterUnenroll, 0)
    }

    func testAdminRunnersUsesScaledAvgWaitUnits() async throws {
        let cookie = try await loginAsAdmin()
        let course = try await makeCourse(code: "WAIT101", name: "Wait Course")
        let courseID = try course.requireID()
        let setup = try await makeSetup(id: "setup_wait_admin", courseID: courseID)
        let student = try await makeUser(username: "wait_student", role: "student")
        let studentID = try student.requireID()
        let submission = try await makeSubmission(
            id: "sub_wait_admin",
            setupID: try setup.requireID(),
            userID: studentID
        )
        submission.workerID = "runner-wait"
        try await submission.update(on: app.db)

        let metric = JobExecutionMetric(
            submissionID: try submission.requireID(),
            jobID: try submission.requireID(),
            testSetupID: try setup.requireID(),
            courseID: courseID,
            assignmentID: nil,
            userID: studentID,
            runnerID: "runner-wait",
            kind: APISubmission.Kind.student,
            attemptNumber: 1,
            enqueuedAt: Date().addingTimeInterval(-120)
        )
        metric.completedAt = Date().addingTimeInterval(-10)
        metric.queueWaitMs = 65_000
        metric.executionMs = 4_000
        metric.totalProcessingMs = 69_000
        metric.finalStatus = "passed"
        try await metric.save(on: app.db)

        await app.workerActivityStore.markActive(
            workerID: "runner-wait",
            hostname: "runner-host",
            runnerVersion: "runner/1.0",
            maxConcurrentJobs: 2,
            activeJobs: 0,
            lastHeartbeatAt: Date()
        )

        try await app.asyncTest(
            .GET, "/admin/runners",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [[String: Any]]
                let row = try XCTUnwrap(json?.first(where: { ($0["workerID"] as? String) == "runner-wait" }))
                XCTAssertEqual(row["avgQueueWaitFormatted"] as? String, "1m 5s")
            })
    }

    func testRunnerDetailShowsStageTimingBreakdownWhenAvailable() async throws {
        let cookie = try await loginAsAdmin()
        let course = try await makeCourse(code: "RUN101", name: "Runner Detail")
        let courseID = try course.requireID()
        let setup = try await makeSetup(id: "setup_runner_detail", courseID: courseID)
        let student = try await makeUser(username: "runner_detail_student", role: "student")
        let studentID = try student.requireID()
        let submission = try await makeSubmission(
            id: "sub_runner_detail",
            setupID: try setup.requireID(),
            userID: studentID
        )
        submission.workerID = "runner-detail"
        try await submission.update(on: app.db)

        let metric = JobExecutionMetric(
            submissionID: try submission.requireID(),
            jobID: try submission.requireID(),
            testSetupID: try setup.requireID(),
            courseID: courseID,
            assignmentID: nil,
            userID: studentID,
            runnerID: "runner-detail",
            kind: APISubmission.Kind.student,
            attemptNumber: 1,
            enqueuedAt: Date().addingTimeInterval(-30)
        )
        metric.completedAt = Date().addingTimeInterval(-5)
        metric.queueWaitMs = 1_000
        metric.executionMs = 4_000
        metric.totalProcessingMs = 8_000
        metric.testSetupAcquireMs = 200
        metric.submissionDownloadMs = 150
        metric.workdirSetupMs = 10
        metric.submissionDirSetupMs = 15
        metric.submissionUnpackMs = 20
        metric.starterCleanupMs = 5
        metric.submissionPrepareMs = 35
        metric.runtimeHelperSetupMs = 15
        metric.makeStepMs = 25
        metric.finalStatus = "passed"
        // 12 MiB workspace footprint — verifies the new Peak Disk column.
        metric.workdirPeakBytes = 12 * 1024 * 1024
        try await metric.save(on: app.db)

        let snapshot = RunnerSnapshot(
            runnerID: "runner-detail",
            recordedAt: Date().addingTimeInterval(-60),
            activeJobs: 1,
            maxJobs: 2,
            availableCapacity: 1,
            hostname: "runner-host",
            runnerVersion: "runner/1.1",
            lastPollAt: Date().addingTimeInterval(-15),
            lastHeartbeatAt: Date().addingTimeInterval(-10),
            serverAssignedJobCountSinceStart: 1
        )
        try await snapshot.save(on: app.db)

        await app.workerActivityStore.markActive(
            workerID: "runner-detail",
            hostname: "runner-host",
            runnerVersion: "runner/1.1",
            maxConcurrentJobs: 2,
            activeJobs: 0,
            lastHeartbeatAt: Date()
        )

        try await app.asyncTest(
            .GET, "/admin/runners/runner-detail",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("Avg cache acquire:"))
                XCTAssertTrue(body.contains("200ms"))
                XCTAssertTrue(body.contains("Avg download:"))
                XCTAssertTrue(body.contains("150ms"))
                XCTAssertTrue(body.contains("Avg prep:"))
                XCTAssertTrue(body.contains("100ms"))
                XCTAssertTrue(body.contains("sortable-table"))
                XCTAssertTrue(body.contains("Active Jobs"))
                XCTAssertTrue(body.contains("1 / 2"))
                XCTAssertTrue(body.contains("Utilization %"))
                XCTAssertFalse(body.contains(">Max Jobs<"))
                XCTAssertFalse(body.contains(">Available<"))
                // Peak Disk column shows the formatted bytes; Setup/Other column
                // was removed in favour of it.
                XCTAssertTrue(body.contains("Peak Disk"))
                XCTAssertTrue(body.contains("12.0 MB"))
                XCTAssertFalse(body.contains(">Setup/Other<"))
            })
    }
}
