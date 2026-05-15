import Foundation
import Testing

@testable import Core

struct CourseBundleManifestTests {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Helpers

    private func minimalManifest() -> CourseBundleManifest {
        CourseBundleManifest(
            exportedAt: Date(timeIntervalSince1970: 0),
            exportedBy: "admin",
            chickadeeVersion: "0.4.36",
            course: BundledCourse(code: "CS101", name: "Intro CS", enrollmentMode: .open),
            users: [],
            enrolledUserBundleIDs: [],
            assignments: [],
            testSetups: [],
            submissions: [],
            results: []
        )
    }

    // MARK: - Round-trip

    @Test func emptyManifestRoundTrip() throws {
        let manifest = minimalManifest()
        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(CourseBundleManifest.self, from: data)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.exportedBy == "admin")
        #expect(decoded.chickadeeVersion == "0.4.36")
        #expect(decoded.course.code == "CS101")
        #expect(decoded.users.isEmpty)
        #expect(decoded.assignments.isEmpty)
        #expect(decoded.submissions.isEmpty)
        #expect(decoded.results.isEmpty)
    }

    @Test func fullManifestRoundTrip() throws {
        let user = BundledUser(
            bundleID: "user_1", username: "alice", displayName: "Alice",
            email: "alice@example.com", role: "student"
        )
        let setup = BundledTestSetup(
            bundleID: "ts_1", originalID: "setup_abc123",
            manifest: #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#,
            zipFilename: "testsetups/setup_abc123.zip"
        )
        let assignment = BundledAssignment(
            bundleID: "a_1", title: "Warmup",
            dueAt: Date(timeIntervalSince1970: 86400), isOpen: false,
            sortOrder: 0, testSetupBundleID: "ts_1"
        )
        let submission = BundledSubmission(
            bundleID: "sub_1", userBundleID: "user_1", testSetupBundleID: "ts_1",
            attemptNumber: 1, submittedAt: Date(timeIntervalSince1970: 1000),
            filename: "warmup.py", submissionFilename: "submissions/sub_xyz.py"
        )
        let result = BundledResult(
            submissionBundleID: "sub_1",
            collectionJSON: #"{"submissionID":"sub_xyz"}"#,
            source: "worker", receivedAt: Date(timeIntervalSince1970: 2000)
        )

        let manifest = CourseBundleManifest(
            exportedAt: Date(timeIntervalSince1970: 0),
            exportedBy: "admin",
            chickadeeVersion: "0.4.36",
            course: BundledCourse(code: "CS101", name: "Intro CS", enrollmentMode: .open),
            users: [user],
            enrolledUserBundleIDs: ["user_1"],
            assignments: [assignment],
            testSetups: [setup],
            submissions: [submission],
            results: [result]
        )

        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(CourseBundleManifest.self, from: data)

        #expect(decoded.users.count == 1)
        #expect(decoded.users[0].username == "alice")
        #expect(decoded.users[0].role == "student")
        #expect(decoded.enrolledUserBundleIDs == ["user_1"])
        #expect(decoded.assignments.count == 1)
        #expect(decoded.assignments[0].title == "Warmup")
        #expect(decoded.testSetups.count == 1)
        #expect(decoded.testSetups[0].bundleID == "ts_1")
        #expect(decoded.submissions.count == 1)
        #expect(decoded.submissions[0].filename == "warmup.py")
        #expect(decoded.results.count == 1)
        #expect(decoded.results[0].source == "worker")
    }

    // MARK: - Backward compatibility: enrollmentMode nil → openEnrollment

    @Test func bundledCourseBackwardCompatEnrollmentModeAbsent() throws {
        // Old bundle JSON without enrollmentMode — only openEnrollment present.
        let json = """
            { "code": "CS101", "name": "Intro CS", "openEnrollment": true }
            """.data(using: .utf8)!

        let course = try decoder.decode(BundledCourse.self, from: json)
        #expect(course.enrollmentMode == nil)
        #expect(course.openEnrollment == true)
    }

    @Test func bundledCourseEnrollmentModePresent() throws {
        let json = """
            { "code": "CS101", "name": "Intro CS", "enrollmentMode": "auto" }
            """.data(using: .utf8)!

        let course = try decoder.decode(BundledCourse.self, from: json)
        #expect(course.enrollmentMode == .auto)
        #expect(course.openEnrollment == nil)
    }

    // MARK: - bundledCourseEnrollmentMode resolver
    //
    // Pin the resolver so v0.6.0 can drop the `openEnrollment` branch with
    // confidence — when the deprecation lands, only the legacy-bundle cases
    // below need updating (or deleting).

    @Test func enrollmentModeResolver_prefersExplicitMode() {
        let course = BundledCourse(
            code: "CS101", name: "Intro CS",
            enrollmentMode: .auto, openEnrollment: false
        )
        #expect(bundledCourseEnrollmentMode(course) == .auto)
    }

    @Test func enrollmentModeResolver_legacyOpenEnrollmentFalseMapsToClosed() {
        let course = BundledCourse(
            code: "CS101", name: "Intro CS",
            enrollmentMode: nil, openEnrollment: false
        )
        #expect(bundledCourseEnrollmentMode(course) == .closed)
    }

    @Test func enrollmentModeResolver_legacyOpenEnrollmentTrueMapsToOpen() {
        let course = BundledCourse(
            code: "CS101", name: "Intro CS",
            enrollmentMode: nil, openEnrollment: true
        )
        #expect(bundledCourseEnrollmentMode(course) == .open)
    }

    @Test func enrollmentModeResolver_bothFieldsMissingDefaultsToOpen() {
        let course = BundledCourse(
            code: "CS101", name: "Intro CS",
            enrollmentMode: nil, openEnrollment: nil
        )
        #expect(bundledCourseEnrollmentMode(course) == .open)
    }

    // MARK: - CourseEnrollmentMode raw values

    @Test(
        arguments: zip(
            [CourseEnrollmentMode.open, .auto, .closed],
            ["open", "auto", "closed"]
        ))
    func enrollmentModeRawValues(mode: CourseEnrollmentMode, raw: String) {
        #expect(mode.rawValue == raw)
    }

    @Test(arguments: [CourseEnrollmentMode.open, .auto, .closed])
    func enrollmentModeRoundTrip(mode: CourseEnrollmentMode) throws {
        let data = try encoder.encode(mode)
        let decoded = try decoder.decode(CourseEnrollmentMode.self, from: data)
        #expect(decoded == mode)
    }

    // MARK: - Optional fields

    @Test func bundledUserNilOptionals() throws {
        let user = BundledUser(
            bundleID: "user_2", username: "bob",
            displayName: nil, email: nil, role: "student"
        )
        let data = try encoder.encode(user)
        let decoded = try decoder.decode(BundledUser.self, from: data)
        #expect(decoded.displayName == nil)
        #expect(decoded.email == nil)
    }

    @Test func bundledAssignmentNilDueAt() throws {
        let assignment = BundledAssignment(
            bundleID: "a_2", title: "Lab 1",
            dueAt: nil, isOpen: true,
            sortOrder: nil, testSetupBundleID: "ts_1"
        )
        let data = try encoder.encode(assignment)
        let decoded = try decoder.decode(BundledAssignment.self, from: data)
        #expect(decoded.dueAt == nil)
        #expect(decoded.sortOrder == nil)
    }

    @Test func bundledResultNilReceivedAt() throws {
        let result = BundledResult(
            submissionBundleID: "sub_1",
            collectionJSON: "{}",
            source: "browser",
            receivedAt: nil
        )
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(BundledResult.self, from: data)
        #expect(decoded.receivedAt == nil)
        #expect(decoded.source == "browser")
    }
}
