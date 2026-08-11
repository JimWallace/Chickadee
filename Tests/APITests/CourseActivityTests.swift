// Tests/APITests/CourseActivityTests.swift
//
// The merged course activity timeline (#421): content edits from
// `assignment_versions` and course events from `audit_log`, interleaved,
// scoped to one course, visible to course staff.
//
// What these pin is the part a reader depends on and cannot see for
// themselves: that both sources actually reach the timeline, that it is
// chronological rather than source-grouped, that another course's history never
// leaks in, and that the audit half is course-scoped by an indexed column
// rather than by luck.
//
// `.serialized`: the fixtures spawn zip subprocesses to build snapshots.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseActivityTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-activity")
    }

    // MARK: - Fixtures

    private func makeCourse(_ app: Application, code: String) async throws -> UUID {
        let course = APICourse(code: code, name: "Activity \(code)", enrollmentMode: .auto)
        try await course.save(on: app.db)
        return try course.requireID()
    }

    @discardableResult
    private func makeAssignment(
        _ app: Application, courseID: UUID, title: String
    ) async throws -> (assignment: APIAssignment, setup: APITestSetup) {
        let setupID = "act_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try writeZip(at: zipPath, entries: [("test_a.sh", "exit 0\n")])
        let setup = APITestSetup(
            id: setupID,
            manifest: #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#,
            zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: title, dueAt: nil, isOpen: false,
            deadlineOverrideActive: false, courseID: courseID)
        try await assignment.save(on: app.db)
        return (assignment, setup)
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("act-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            try Data(content.utf8).write(to: root.appendingPathComponent(name))
        }
        try writeZipFixture(of: root, to: zipPath)
    }

    /// A version row written directly, so a test can control its timestamp and
    /// actor without driving a whole edit through the capture path.
    private func seedVersion(
        _ app: Application,
        on target: (assignment: APIAssignment, setup: APITestSetup),
        actor: String?, origin: String, number: Int, at date: Date, summary: String? = nil
    ) async throws {
        let (assignment, setup) = target
        let blobs = AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
        let snapshot = try await AssignmentVersionSnapshotBuilder.build(setup: setup, blobs: blobs)
        let row = APIAssignmentVersion(
            testSetupID: setup.id ?? "",
            assignmentID: assignment.id,
            courseID: assignment.courseID,
            versionNumber: number,
            snapshot: snapshot,
            actorUsername: actor,
            origin: origin,
            summary: summary)
        try await row.create(on: app.db)
        row.createdAt = date
        try await row.update(on: app.db)
    }

    private func seedAuditEvent(
        _ app: Application, courseID: UUID?, action: AuditAction, actor: String,
        at date: Date, metadata: [String: String] = [:]
    ) async throws {
        let encoded =
            try String(
                data: JSONEncoder().encode(metadata), encoding: .utf8) ?? "{}"
        let entry = APIAuditLogEntry(
            actorUsername: actor,
            action: action.rawValue,
            targetType: AuditTargetType.assignment.rawValue,
            metadata: metadata.isEmpty ? nil : encoded,
            courseID: courseID)
        try await entry.create(on: app.db)
        entry.createdAt = date
        try await entry.update(on: app.db)
    }

    // MARK: - The merge

    /// The headline: both sources reach the timeline, interleaved by time
    /// rather than grouped by source. A reader asking "what happened last
    /// Tuesday" gets one ordered answer.
    @Test func timelineInterleavesContentEditsAndCourseEvents() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "ACT1")
            let (assignment, setup) = try await makeAssignment(
                app, courseID: courseID, title: "Lab 1")
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            try await seedVersion(
                app, on: (assignment, setup), actor: "ta_kim",
                origin: "web:PUT /instructor/:assignmentID/suite", number: 1,
                at: base)
            try await seedAuditEvent(
                app, courseID: courseID, action: .assignmentVisibilityChanged,
                actor: "prof_lee", at: base.addingTimeInterval(60),
                metadata: ["assignment": assignment.publicID, "visibility": "open"])
            try await seedVersion(
                app, on: (assignment, setup), actor: "ta_kim",
                origin: "mcp:update_suite", number: 2,
                at: base.addingTimeInterval(120))

            let rows = try await CourseActivityService.timeline(courseID: courseID, on: app.db)

            #expect(rows.count == 3)
            // Newest first, and the audit event sits BETWEEN the two content
            // edits rather than in a block of its own.
            #expect(rows[0].category == "Content edit")
            #expect(rows[1].category == AuditCategory.assignments.rawValue)
            #expect(rows[2].category == "Content edit")
            #expect(rows[1].actor == "prof_lee")
            #expect(rows[1].detail.contains("visibility: open"))
        }
    }

    /// A course's timeline must never show another course's history — the whole
    /// point of scoping it to staff of that course.
    @Test func anotherCoursesActivityNeverLeaksIn() async throws {
        try await withApp(app) { app in
            let mine = try await makeCourse(app, code: "ACTMINE")
            let theirs = try await makeCourse(app, code: "ACTTHEIRS")
            let (mineAssignment, mineSetup) = try await makeAssignment(
                app, courseID: mine, title: "My lab")
            let (theirsAssignment, theirsSetup) = try await makeAssignment(
                app, courseID: theirs, title: "Their lab")
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            try await seedVersion(
                app, on: (mineAssignment, mineSetup), actor: "me",
                origin: "web:edit", number: 1, at: base)
            try await seedVersion(
                app, on: (theirsAssignment, theirsSetup), actor: "them",
                origin: "web:edit", number: 1, at: base.addingTimeInterval(10))
            try await seedAuditEvent(
                app, courseID: theirs, action: .assignmentDeleted, actor: "them",
                at: base.addingTimeInterval(20))

            let rows = try await CourseActivityService.timeline(courseID: mine, on: app.db)

            #expect(rows.count == 1)
            #expect(rows[0].target == "My lab")
            #expect(!rows.contains { $0.actor == "them" })
        }
    }

    /// Deployment-wide events (a login, a runner secret rotation) carry no
    /// course and must not surface in any course's view.
    @Test func unscopedAuditEventsAreExcluded() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "ACTUNS")
            try await seedAuditEvent(
                app, courseID: nil, action: .runnerSecretRotated, actor: "admin",
                at: Date(timeIntervalSince1970: 1_700_000_000))

            let rows = try await CourseActivityService.timeline(courseID: courseID, on: app.db)
            #expect(rows.isEmpty)
        }
    }

    @Test func filteringByActorNarrowsBothSources() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "ACTFIL")
            let (assignment, setup) = try await makeAssignment(
                app, courseID: courseID, title: "Lab F")
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            try await seedVersion(
                app, on: (assignment, setup), actor: "ta_kim",
                origin: "web:edit", number: 1, at: base)
            try await seedVersion(
                app, on: (assignment, setup), actor: "prof_lee",
                origin: "web:edit", number: 2, at: base.addingTimeInterval(10))
            try await seedAuditEvent(
                app, courseID: courseID, action: .assignmentCreated, actor: "ta_kim",
                at: base.addingTimeInterval(20))
            try await seedAuditEvent(
                app, courseID: courseID, action: .assignmentCreated, actor: "prof_lee",
                at: base.addingTimeInterval(30))

            let rows = try await CourseActivityService.timeline(
                courseID: courseID, actorFilter: "ta_kim", on: app.db)

            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.actor == "ta_kim" })
        }
    }

    /// A version whose assignment was deleted still belongs in the history —
    /// the deletion is exactly what a reader is trying to understand. It must
    /// render without a broken link rather than disappear.
    @Test func aDeletedAssignmentsEditsStillAppear() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "ACTDEL")
            let (assignment, setup) = try await makeAssignment(
                app, courseID: courseID, title: "Doomed lab")
            try await seedVersion(
                app, on: (assignment, setup), actor: "ta_kim",
                origin: "web:edit", number: 1,
                at: Date(timeIntervalSince1970: 1_700_000_000))

            try await assignment.delete(on: app.db)

            let rows = try await CourseActivityService.timeline(courseID: courseID, on: app.db)
            #expect(rows.count == 1)
            #expect(rows[0].target == "(deleted assignment)")
            #expect(rows[0].link == nil)
        }
    }

    /// System-originated snapshots (baseline, clone seed) have no human behind
    /// them; the column says "system" rather than going blank.
    @Test func systemOriginatedVersionsAreLabelled() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "ACTSYS")
            let (assignment, setup) = try await makeAssignment(
                app, courseID: courseID, title: "Seeded lab")
            try await seedVersion(
                app, on: (assignment, setup), actor: nil,
                origin: AssignmentVersionOrigin.baseline, number: 1,
                at: Date(timeIntervalSince1970: 1_700_000_000))

            let rows = try await CourseActivityService.timeline(courseID: courseID, on: app.db)
            #expect(rows[0].actor == "system")
            #expect(rows[0].summary.contains("Baseline"))
        }
    }

    @Test func aRestoreReadsAsARestore() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "ACTRES")
            let (assignment, setup) = try await makeAssignment(
                app, courseID: courseID, title: "Restored lab")
            let blobs = AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
            let snapshot = try await AssignmentVersionSnapshotBuilder.build(
                setup: setup, blobs: blobs)
            let row = APIAssignmentVersion(
                testSetupID: setup.id ?? "", assignmentID: assignment.id,
                courseID: courseID, versionNumber: 2, snapshot: snapshot,
                actorUsername: "prof_lee", origin: AssignmentVersionOrigin.restore(of: 1),
                restoredFromVersion: 1)
            try await row.create(on: app.db)

            let rows = try await CourseActivityService.timeline(courseID: courseID, on: app.db)
            #expect(rows[0].summary == "Restored version 1")
        }
    }

    // MARK: - Course scoping of audit rows

    /// Course-scoped call sites have always set `course_id` in the metadata
    /// JSON. The logger derives the indexed column from it, so every existing
    /// enrollment/staff event lands in the right course view without its call
    /// site being touched.
    @Test func courseScopeIsDerivedFromMetadataWhenNotPassed() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "ACTMETA")
            let request = Request(application: app, on: app.eventLoopGroup.any())

            await AuditLogger.record(
                action: .enrollmentRoleChanged,
                targetType: .enrollment,
                targetID: UUID().uuidString,
                metadata: ["course_id": courseID.uuidString, "role": "ta"],
                on: request)

            let entry = try #require(
                try await APIAuditLogEntry.query(on: app.db)
                    .filter(\.$action == AuditAction.enrollmentRoleChanged.rawValue)
                    .first())
            #expect(entry.courseID == courseID)

            let rows = try await CourseActivityService.timeline(courseID: courseID, on: app.db)
            #expect(rows.count == 1)
            #expect(rows[0].detail.contains("role: ta"))
        }
    }

    /// The lifecycle helper always scopes, so a new call site cannot forget.
    @Test func lifecycleHelperAlwaysScopesToTheAssignmentsCourse() async throws {
        try await withApp(app) { app in
            let courseID = try await makeCourse(app, code: "ACTLIFE")
            let (assignment, _) = try await makeAssignment(
                app, courseID: courseID, title: "Lifecycle lab")
            let request = Request(application: app, on: app.eventLoopGroup.any())

            await AuditLogger.recordAssignmentLifecycle(
                .assignmentDeleted, assignment: assignment,
                metadata: ["title": assignment.title], on: request)

            let entry = try #require(
                try await APIAuditLogEntry.query(on: app.db)
                    .filter(\.$action == AuditAction.assignmentDeleted.rawValue)
                    .first())
            #expect(entry.courseID == courseID)
            #expect(entry.targetID == assignment.id?.uuidString)
        }
    }
}

/// Action-vocabulary checks. A struct suite: it owns no Vapor app.
@Suite struct AssignmentLifecycleAuditActionTests {

    /// The events content versioning deliberately does NOT record must all
    /// exist as audit actions — this is the half of #421 versioning left open.
    @Test(arguments: [
        AuditAction.assignmentCreated, .assignmentCloned, .assignmentDeleted,
        .assignmentVisibilityChanged, .assignmentDueDateChanged,
    ])
    func lifecycleActionsAreCategorisedAsAssignments(_ action: AuditAction) {
        #expect(action.category == .assignments)
        #expect(!action.label.isEmpty)
    }
}

/// HTTP-level checks for `GET /instructor/activity`: it renders, it is gated to
/// course staff, and it shows real rows.
@Suite(.serialized) final class CourseActivityPageTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-activity-page")
    }

    /// A staff member of a course that already has one recorded content edit.
    private func fixture(_ app: Application, username: String) async throws -> String {
        let course = APICourse(code: "ACTPG", name: "Activity Page", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "actpg_setup"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("actpg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("exit 0\n".utf8).write(to: root.appendingPathComponent("test_a.sh"))
        try writeZipFixture(of: root, to: zipPath)

        let setup = APITestSetup(
            id: setupID,
            manifest: #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#,
            zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Rendered lab", dueAt: nil, isOpen: false,
            deadlineOverrideActive: false, courseID: courseID)
        try await assignment.save(on: app.db)

        _ = try await AssignmentVersionStore.record(
            setup: setup,
            request: AssignmentVersionRequest(origin: "web:PUT /instructor/:assignmentID/suite"),
            testSetupsDirectory: app.testSetupsDirectory,
            on: app.db)

        let cookie = try await loginUser(
            username: username, password: "pw", role: "instructor", on: app)
        try await promoteToInstructor(username, on: app)
        return cookie
    }

    @Test func activityPageRendersTheTimelineForStaff() async throws {
        try await withApp(app) { app in
            let cookie = try await fixture(app, username: "act_inst")

            try await app.asyncTest(
                .GET, "/instructor/activity",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("Recent activity"))
                    #expect(body.contains("Rendered lab"))
                    #expect(body.contains("Content edit"))
                })
        }
    }

    /// The `/instructor` group is gated by `ActiveCourseStaffMiddleware`, so a
    /// plain student never reaches the timeline — the scoping this page relies
    /// on for its "course staff only" guarantee.
    @Test func activityPageIsClosedToNonStaff() async throws {
        try await withApp(app) { app in
            _ = try await fixture(app, username: "act_inst2")
            let studentCookie = try await loginUser(
                username: "act_student", password: "pw", role: "user", on: app)

            try await app.asyncTest(
                .GET, "/instructor/activity",
                beforeRequest: { req in req.headers.add(name: .cookie, value: studentCookie) },
                afterResponse: { res in
                    #expect(res.status != .ok)
                })
        }
    }
}
