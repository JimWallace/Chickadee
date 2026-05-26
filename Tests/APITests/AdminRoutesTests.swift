import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

/// Trivial tail of a middleware chain for unit-testing a single middleware.
private struct PassthroughResponder: AsyncResponder {
    func respond(to request: Request) async throws -> Response {
        Response(status: .ok)
    }
}

@Suite(.serialized) final class AdminRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin")
    }

    private func loginAsAdmin() async throws -> String {
        try await loginUser(username: "admin_routes", password: "testpassword", role: "admin", on: app)
    }

    private func csrfCookieAndToken(_ cookie: String, path: String = "/admin") async throws -> (String, String) {
        let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
        return (boundCookie, token)
    }

    // Suite-specific defaults that wrap the centralized fixture
    // builders in Tests/APITests/Fixtures.swift.  Kept as private
    // wrappers (not call-site `makeTestCourse(on: app, ...)`) so the
    // many call sites below don't churn.

    @discardableResult
    private func makeCourse(
        code: String = "ADM101",
        name: String = "Admin Test Course",
        archived: Bool = false,
        mode: CourseEnrollmentMode = .open
    ) async throws -> APICourse {
        try await makeTestCourse(on: app, code: code, name: name, archived: archived, mode: mode)
    }

    @discardableResult
    private func makeUser(username: String, role: String = "student") async throws -> APIUser {
        try await makeTestUser(on: app, username: username, role: role)
    }

    @discardableResult
    private func makeSetup(
        id: String,
        courseID: UUID,
        withNotebook: Bool = true
    ) async throws -> APITestSetup {
        try await makeTestSetup(on: app, id: id, courseID: courseID, withNotebook: withNotebook)
    }

    @discardableResult
    private func makeAssignment(
        testSetupID: String,
        courseID: UUID,
        title: String = "Admin Lab"
    ) async throws -> APIAssignment {
        try await makeTestAssignment(on: app, testSetupID: testSetupID, courseID: courseID, title: title)
    }

    @discardableResult
    private func makeEnrollment(userID: UUID, courseID: UUID) async throws -> APICourseEnrollment {
        try await makeTestEnrollment(on: app, userID: userID, courseID: courseID)
    }

    @discardableResult
    private func makeSubmission(
        id: String,
        setupID: String,
        userID: UUID
    ) async throws -> APISubmission {
        try await makeTestSubmission(on: app, id: id, setupID: setupID, userID: userID)
    }

    @discardableResult
    private func makeResult(submissionID: String) async throws -> APIResult {
        try await makeTestResult(on: app, submissionID: submissionID)
    }

    @Test func changeRoleUpdatesUserRole() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin")
                })

            let updated = try await APIUser.find(userID, on: app.db)
            #expect(updated?.role == "instructor")

        }
    }

    @Test func updateWorkerSecretPersistsRuntimeOverride() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let (boundCookie, token) = try await csrfCookieAndToken(cookie)

            try await app.asyncTest(
                .POST, "/admin/runner-secret",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["secret": " new-runner-secret ", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin")
                })

            let runtime = await app.workerSecretStore.runtimeOverrideValue()
            #expect(runtime == "new-runner-secret")
            #expect(readWorkerSecretFromDisk(workerSecretFilePath: app.workerSecretFilePath) == "new-runner-secret")

        }
    }

    @Test func writeWorkerSecretToDiskSetsOwnerOnlyPermissions() async throws {
        try await withApp(app) { _ in
            // The worker secret is the HMAC signing key for runner↔server
            // requests; default umask leaves it world-readable on Linux, so
            // writeWorkerSecretToDisk must enforce 0o600.
            let path = app.workerSecretFilePath
            writeWorkerSecretToDisk(secret: "mode-check-secret", workerSecretFilePath: path)

            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(perms & 0o777 == 0o600, "Expected .worker-secret to be 0600; got \(String(perms, radix: 8))")

        }
    }

    @Test func readWorkerSecretFromDiskTightensExistingPermissions() async throws {
        try await withApp(app) { _ in
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
            #expect(perms & 0o777 == 0o600)

        }
    }

    @Test func updateWorkerSecretBlankRestoresPersistedValue() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .seeOther)
                })

            let runtime = await app.workerSecretStore.runtimeOverrideValue()
            #expect(runtime == "persisted-secret")

        }
    }

    @Test func updateLocalRunnerAutoStartPersistsSetting() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin")
                })

            let isEnabled = await app.localRunnerAutoStartStore.isEnabled()
            #expect(isEnabled)
            #expect(readLocalRunnerAutoStartFromDisk(filePath: app.localRunnerAutoStartFilePath) == true)

        }
    }

    @Test func adminDashboardShowsJobsProcessedCardLabel() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()

            try await app.asyncTest(
                .GET, "/admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("24h Jobs Processed"))
                    #expect(body.contains("24h Peak Util") == false)
                })

        }
    }

    @Test func storageTabShowsBreakdown() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()

            try await app.asyncTest(
                .GET, "/admin/storage",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains(">Storage<"))
                    #expect(body.contains(">Submissions<"))
                    #expect(body.contains(">Test Setups<"))
                    #expect(body.contains(">Database<"))
                    #expect(body.contains("aria-current=\"page\""))
                })

            // The Storage panel must no longer appear on the Overview tab.
            // (Use a storage-only label — the Overview courses table now has its
            // own "Submissions" column header.)
            try await app.asyncTest(
                .GET, "/admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains(">Test Setups<") == false)
                })
        }
    }

    @Test func adminTabBarPresentWithOverviewActive() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            try await app.asyncTest(
                .GET, "/admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("class=\"admin-tabs\""))
                    #expect(body.contains("href=\"/admin/users\""))
                    #expect(body.contains("href=\"/admin/storage\""))
                    #expect(body.contains("href=\"/admin/audit\""))
                    #expect(body.contains("href=\"/admin/alerts\""))
                    // Overview is the active tab.
                    #expect(body.contains("href=\"/admin\" aria-current=\"page\""))
                    // The inline audit/alerts buttons were removed from Overview.
                    #expect(body.contains(">Server health alerts</a>") == false)
                })
        }
    }

    @Test func usersTabDefaultsToMostRecentLastSeenFirst() async throws {
        try await withApp(app) { _ in
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
                .GET, "/admin/users",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("data-sort-key=\"last-seen\""))
                    #expect(body.contains("sortUsersByHeader(defaultUserHeader, 'desc');"))
                    let recentIndex = try #require(body.range(of: "recent_seen")?.lowerBound)
                    let olderIndex = try #require(body.range(of: "older_seen")?.lowerBound)
                    let neverIndex = try #require(body.range(of: "never_seen")?.lowerBound)
                    XCTAssertLessThan(recentIndex, olderIndex)
                    XCTAssertLessThan(olderIndex, neverIndex)
                })

        }
    }

    // MARK: - POST /admin/users/:userID/delete — FK cleanup (#562)

    /// Deleting a user must CASCADE-delete the `class_achievements` rows
    /// that reference them.  The DB-level FK constraint added by
    /// `AddUserFKConstraints` covers Postgres; the admin handler enforces
    /// the same semantics in application code so SQLite (which can't add
    /// FK constraints to existing columns) behaves identically.
    @Test func deleteUserCascadesClassAchievements() async throws {
        try await withApp(app) { _ in
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
            #expect(preDeleteCount == 1)

            let (boundCookie, token) = try await csrfCookieAndToken(cookie)
            try await app.asyncTest(
                .POST, "/admin/users/\(studentID.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            let reloadedUser = try await APIUser.find(studentID, on: app.db)
            #expect(reloadedUser == nil)
            let postDeleteCount = try await APIClassAchievement.query(on: app.db)
                .filter(\.$userID == studentID)
                .count()
            #expect(postDeleteCount == 0, "class_achievements rows referencing the deleted user must be removed")

        }
    }

    /// Deleting an instructor who has retested submissions must NULL out
    /// `submissions.retested_by_user_id` — the submission row stays
    /// (immutable grade history) but the retest attribution drops.
    @Test func deleteUserNullsRetestedByReferences() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .seeOther)
                }
            )

            let reloadedInstructor = try await APIUser.find(instructorID, on: app.db)
            #expect(reloadedInstructor == nil)
            let reloaded = try await APISubmission.find("fk_null_sub", on: app.db)
            #expect(reloaded != nil, "Submission row must be preserved as immutable grade history")
            #expect(
                reloaded?.retestedByUserID == nil, "retested_by_user_id must clear when the referenced user is deleted")

        }
    }

    @Test func adminUserActionsRenderDeleteInUsersTableOnly() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let managedUser = try await makeUser(username: "managed_for_actions", role: "student")
            let userID = try managedUser.requireID()

            try await app.asyncTest(
                .GET, "/admin/users",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("<th>Actions</th>"))
                    #expect(body.contains("<th>Courses</th>") == false)
                    #expect(body.contains("/admin/users/\(userID.uuidString)/delete"))
                    #expect(body.contains("aria-label=\"Delete user\""))
                })

            try await app.asyncTest(
                .GET, "/admin/users/\(userID.uuidString)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains(">Delete User<") == false)
                    #expect(body.contains("/admin/users/\(userID.uuidString)/delete") == false)
                })

        }
    }

    @Test func editCourseUpdatesFields() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeCourse(code: "EDIT101", name: "Original Name")
            let courseID = try course.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

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
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin/courses/\(courseID.uuidString)")
                })

            let updated = try await APICourse.find(courseID, on: app.db)
            #expect(updated?.code == "EDIT201")
            #expect(updated?.name == "Updated Name")

        }
    }

    @Test func toggleCourseArchiveFlipsArchivedState() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeCourse(code: "ARCH101", name: "Archive Me", archived: false)
            let courseID = try course.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/archive",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let updated = try await APICourse.find(courseID, on: app.db)
            #expect(updated?.isArchived == true)

        }
    }

    @Test func deleteCourseRemovesRecordsAndFilesForArchivedCourse() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let student = try await makeUser(username: "delete_student", role: "student")
            let studentID = try student.requireID()
            let course = try await makeCourse(code: "DEL101", name: "Delete Me", archived: true)
            // Past the 365-day retention window so deletion is permitted.
            course.archivedAt = Date().addingTimeInterval(-400 * 86_400)
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            let setup = try await makeSetup(id: "setup_delete_admin", courseID: courseID)
            _ = try await makeAssignment(testSetupID: "setup_delete_admin", courseID: courseID)
            _ = try await makeEnrollment(userID: studentID, courseID: courseID)
            let submission = try await makeSubmission(
                id: "sub_delete_admin", setupID: "setup_delete_admin", userID: studentID)
            _ = try await makeResult(submissionID: try submission.requireID())
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.hasPrefix("/admin/retention") == true)
                })

            let deletedCourse = try await APICourse.find(courseID, on: app.db)
            let assignmentCount = try await APIAssignment.query(on: app.db).filter(\.$courseID == courseID).count()
            let setupCount = try await APITestSetup.query(on: app.db).filter(\.$courseID == courseID).count()
            let enrollmentCount = try await APICourseEnrollment.query(on: app.db).filter(\.$course.$id == courseID)
                .count()
            let submissionCount = try await APISubmission.query(on: app.db).filter(
                \.$testSetupID == "setup_delete_admin"
            )
            .count()
            let resultCount = try await APIResult.query(on: app.db).count()
            #expect(deletedCourse == nil)
            #expect(assignmentCount == 0)
            #expect(setupCount == 0)
            #expect(enrollmentCount == 0)
            #expect(submissionCount == 0)
            #expect(resultCount == 0)
            #expect(FileManager.default.fileExists(atPath: app.testSetupsDirectory + "setup_delete_admin.zip") == false)
            #expect(
                FileManager.default.fileExists(atPath: app.testSetupsDirectory + "setup_delete_admin.ipynb") == false)
            #expect(FileManager.default.fileExists(atPath: submission.zipPath) == false)
            _ = setup

        }
    }

    @Test func deleteCourseRejectedWhenRetentionWindowNotElapsed() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeCourse(code: "DELRECENT", name: "Recently Archived", archived: true)
            // Archived just now — well inside the retention window.
            course.archivedAt = Date()
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("error=") == true)
                })

            // The course must survive — deletion was refused.
            let survivor = try await APICourse.find(courseID, on: app.db)
            #expect(survivor != nil)
        }
    }

    @Test func adminEnrollAndUnenrollUserMutatesEnrollment() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin/users/\(userID.uuidString)")
                })

            let enrollmentCountAfterEnroll = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == userID)
                .filter(\.$course.$id == courseID)
                .count()
            #expect(enrollmentCountAfterEnroll == 1)

            let (unenrollCookie, unenrollToken) = try await csrfCookieAndToken(
                cookie, path: "/admin/users/\(userID.uuidString)")
            try await app.asyncTest(
                .POST, "/admin/users/\(userID.uuidString)/unenroll/\(courseID.uuidString)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: unenrollCookie)
                    try req.content.encode(["_csrf": unenrollToken], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin/users/\(userID.uuidString)")
                })

            let enrollmentCountAfterUnenroll = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == userID)
                .filter(\.$course.$id == courseID)
                .count()
            #expect(enrollmentCountAfterUnenroll == 0)

        }
    }

    @Test func adminRunnersUsesScaledAvgWaitUnits() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .ok)
                    let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [[String: Any]]
                    let row = try #require(json?.first(where: { ($0["workerID"] as? String) == "runner-wait" }))
                    #expect(row["avgQueueWaitFormatted"] as? String == "1m 5s")
                })

        }
    }

    @Test func runnerDetailShowsStageTimingBreakdownWhenAvailable() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("Avg cache acquire:"))
                    #expect(body.contains("200ms"))
                    #expect(body.contains("Avg download:"))
                    #expect(body.contains("150ms"))
                    #expect(body.contains("Avg prep:"))
                    #expect(body.contains("100ms"))
                    #expect(body.contains("sortable-table"))
                    #expect(body.contains("Active Jobs"))
                    #expect(body.contains("1 / 2"))
                    #expect(body.contains("Utilization %"))
                    #expect(body.contains(">Max Jobs<") == false)
                    #expect(body.contains(">Available<") == false)
                    // Peak Disk column shows the formatted bytes; Setup/Other column
                    // was removed in favour of it.
                    #expect(body.contains("Peak Disk"))
                    #expect(body.contains("12.0 MB"))
                    #expect(body.contains(">Setup/Other<") == false)
                })

        }
    }

    // Validates the DB-side GROUP BY in assignmentCountsByCourse (incl. UUID
    // decode) on whichever backend the suite runs against — SQLite locally and
    // in the `api-tests` CI job, Postgres in `api-tests-postgres`.
    @Test func assignmentCountsByCourseGroupsPerCourse() async throws {
        try await withApp(app) { _ in
            let courseA = try await makeCourse(code: "GRPA", name: "Group A")
            let courseB = try await makeCourse(code: "GRPB", name: "Group B")
            let aID = try courseA.requireID()
            let bID = try courseB.requireID()
            // Three assignments in A, one in B (distinct setups per assignment).
            for index in 1...3 {
                let setup = try await makeSetup(id: "setup_grp_a\(index)", courseID: aID)
                _ = try await makeAssignment(
                    testSetupID: try setup.requireID(), courseID: aID, title: "A\(index)")
            }
            let setupB = try await makeSetup(id: "setup_grp_b1", courseID: bID)
            _ = try await makeAssignment(testSetupID: try setupB.requireID(), courseID: bID, title: "B1")

            let counts = try await assignmentCountsByCourse(on: app.db)
            #expect(counts[aID] == 3)
            #expect(counts[bID] == 1)
        }
    }

    // Validates the (worker_id, status) GROUP BY in makeWorkerRows: assigned
    // jobs counted separately from processed (complete + failed), per worker.
    @Test func adminRunnersCountsAssignedAndProcessedPerWorker() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeCourse(code: "WRK101", name: "Worker Course")
            let courseID = try course.requireID()
            let setup = try await makeSetup(id: "setup_wrk_counts", courseID: courseID)
            let setupID = try setup.requireID()
            let student = try await makeUser(username: "wrk_counts_student", role: "student")
            let studentID = try student.requireID()

            func makeWorkerSubmission(_ id: String, worker: String, status: String) async throws {
                let submission = try await makeTestSubmission(
                    on: app, id: id, setupID: setupID, userID: studentID, status: status)
                submission.workerID = worker
                try await submission.update(on: app.db)
            }
            // runner-A: 2 complete + 1 failed = 3 processed, plus 1 assigned.
            try await makeWorkerSubmission("sub_wc1", worker: "runner-A", status: "complete")
            try await makeWorkerSubmission("sub_wc2", worker: "runner-A", status: "complete")
            try await makeWorkerSubmission("sub_wc3", worker: "runner-A", status: "failed")
            try await makeWorkerSubmission("sub_wc4", worker: "runner-A", status: "assigned")
            // runner-B: 1 complete.
            try await makeWorkerSubmission("sub_wc5", worker: "runner-B", status: "complete")

            for worker in ["runner-A", "runner-B"] {
                await app.workerActivityStore.markActive(
                    workerID: worker,
                    hostname: "runner-host",
                    runnerVersion: "runner/1.0",
                    maxConcurrentJobs: 2,
                    activeJobs: 0,
                    lastHeartbeatAt: Date()
                )
            }

            try await app.asyncTest(
                .GET, "/admin/runners",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [[String: Any]]
                    let rowA = try #require(json?.first(where: { ($0["workerID"] as? String) == "runner-A" }))
                    let rowB = try #require(json?.first(where: { ($0["workerID"] as? String) == "runner-B" }))
                    #expect(rowA["assignedJobs"] as? Int == 1)
                    #expect(rowA["jobsProcessed"] as? Int == 3)
                    #expect(rowB["assignedJobs"] as? Int == 0)
                    #expect(rowB["jobsProcessed"] as? Int == 1)
                })
        }
    }

    // MARK: - Users tab auto-refresh (#users-data feed)

    @Test func usersDataReturnsJSONRows() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            _ = try await makeUser(username: "json_feed_user", role: "instructor")

            try await app.asyncTest(
                .GET, "/admin/users-data",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.headers.contentType == .json)
                    let rows = try res.content.decode([AdminUserRow].self)
                    #expect(rows.contains { $0.username == "json_feed_user" && $0.role == "instructor" })
                    #expect(rows.contains { $0.username == "admin_routes" })
                })
        }
    }

    /// A system-generated poll (carrying `X-Background-Refresh`) must not count
    /// as activity, so a dashboard left open in a tab can't keep a user logged
    /// in past the idle timeout.  A normal request still refreshes activity.
    /// Driven through `UserActivityMiddleware.respond` directly because the
    /// minimal test app doesn't wire the global activity-tracking middleware.
    @Test func backgroundRefreshHeaderSkipsActivityRefresh() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "activity_probe", role: "student")
            let userID = try user.requireID()
            let stale = Date().addingTimeInterval(-3600)
            user.lastSeenAt = stale
            try await user.save(on: app.db)

            let middleware = UserActivityMiddleware(debounceWindow: 60)
            let passthrough = PassthroughResponder()

            // A poll carrying the header must leave last_seen_at untouched.
            let pollReq = Request(
                application: app, method: .GET, url: URI(path: "/admin/users-data"),
                on: app.eventLoopGroup.next())
            pollReq.headers.add(name: UserActivityMiddleware.backgroundRefreshHeader, value: "1")
            pollReq.auth.login(try #require(try await APIUser.find(userID, on: app.db)))
            _ = try await middleware.respond(to: pollReq, chainingTo: passthrough)
            let afterPoll = try #require(try await APIUser.find(userID, on: app.db))
            #expect(
                abs(try #require(afterPoll.lastSeenAt).timeIntervalSince(stale)) < 1,
                "background-refresh poll must not refresh last_seen_at")

            // A normal request (no header) past the debounce must refresh it.
            let normalReq = Request(
                application: app, method: .GET, url: URI(path: "/admin/users"),
                on: app.eventLoopGroup.next())
            normalReq.auth.login(try #require(try await APIUser.find(userID, on: app.db)))
            _ = try await middleware.respond(to: normalReq, chainingTo: passthrough)
            let afterNormal = try #require(try await APIUser.find(userID, on: app.db))
            #expect(
                try #require(afterNormal.lastSeenAt).timeIntervalSince(stale) > 60,
                "a normal (non-poll) request must refresh last_seen_at")
        }
    }

    @Test func allAdminTabsShowVersionBanner() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            for path in ["/admin", "/admin/users", "/admin/storage", "/admin/audit", "/admin/alerts"] {
                try await app.asyncTest(
                    .GET, path,
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: cookie)
                    },
                    afterResponse: { res in
                        #expect(res.status == .ok, "\(path) should render")
                        #expect(
                            String(buffer: res.body).contains("admin-version-banner"),
                            "\(path) should carry the version banner")
                    })
            }
        }
    }

    // MARK: - Storage tab per-assignment breakdown

    @Test func storageTabListsPerAssignmentFootprint() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeCourse(code: "STG101", name: "Storage Course")
            let courseID = try course.requireID()
            _ = try await makeSetup(id: "setup_storage_bd", courseID: courseID)
            _ = try await makeAssignment(
                testSetupID: "setup_storage_bd", courseID: courseID, title: "Storage Breakdown Lab")
            let student = try await makeUser(username: "storage_bd_student", role: "student")
            _ = try await makeSubmission(
                id: "sub_storage_bd", setupID: "setup_storage_bd", userID: try student.requireID())

            try await app.asyncTest(
                .GET, "/admin/storage",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("By Assignment"))
                    #expect(body.contains("Storage Breakdown Lab"))
                    #expect(body.contains(">STG101<"))
                })
        }
    }
}
