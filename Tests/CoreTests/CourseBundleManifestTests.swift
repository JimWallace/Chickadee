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

    // MARK: - bundledCourseEnrollmentMode resolver

    @Test func bundledCourseEnrollmentModePresent() throws {
        let json = Data(
            """
            { "code": "CS101", "name": "Intro CS", "enrollmentMode": "auto" }
            """.utf8)

        let course = try decoder.decode(BundledCourse.self, from: json)
        #expect(course.enrollmentMode == .auto)
    }

    @Test func enrollmentModeResolver_returnsExplicitMode() {
        let course = BundledCourse(
            code: "CS101", name: "Intro CS", enrollmentMode: .auto
        )
        #expect(bundledCourseEnrollmentMode(course) == .auto)
    }

    @Test func enrollmentModeResolver_nilDefaultsToOpen() {
        let course = BundledCourse(
            code: "CS101", name: "Intro CS", enrollmentMode: nil
        )
        #expect(bundledCourseEnrollmentMode(course) == .open)
    }

    // MARK: - Slip-day policy (#1228)

    @Test func slipDayFieldsRoundTrip() throws {
        let course = BundledCourse(
            code: "CS101", name: "Intro CS", enrollmentMode: .open,
            slipDaysEnabled: true, slipDaysPerStudent: 3, slipDayExtensionHours: 48
        )
        let decoded = try decoder.decode(BundledCourse.self, from: try encoder.encode(course))
        let policy = bundledCourseSlipDayPolicy(decoded)
        #expect(policy.enabled)
        #expect(policy.daysPerStudent == 3)
        #expect(policy.extensionHours == 48)
    }

    @Test func legacyBundleWithoutSlipDayFieldsResolvesDisabled() throws {
        // A bundle exported before slip days existed has no keys; resolution
        // falls back to disabled with the defaults.
        let json = #"{ "code": "CS101", "name": "Intro CS" }"#
        let decoded = try decoder.decode(BundledCourse.self, from: Data(json.utf8))
        #expect(decoded.slipDaysEnabled == nil)
        let policy = bundledCourseSlipDayPolicy(decoded)
        #expect(policy.enabled == false)
        #expect(policy.daysPerStudent == SlipDayPolicy.defaultDaysPerStudent)
        #expect(policy.extensionHours == SlipDayPolicy.defaultExtensionHours)
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

    // MARK: - Assignment visibility

    @Test func bundledAssignmentVisibilityRoundTrips() throws {
        let assignment = BundledAssignment(
            bundleID: "a_1", title: "Beta Lab", dueAt: nil, isOpen: false,
            visibility: .preview, sortOrder: 0, testSetupBundleID: "ts_1")
        let decoded = try decoder.decode(
            BundledAssignment.self, from: try encoder.encode(assignment))
        #expect(decoded.visibility == .preview)
        #expect(bundledAssignmentVisibility(decoded) == .preview)
    }

    @Test func legacyBundleWithoutVisibilityFallsBackToIsOpen() throws {
        // A bundle exported before the `visibility` field existed has no key;
        // resolution falls back to the legacy `isOpen` boolean.
        let json = #"""
            {"bundleID":"a_1","title":"Old","dueAt":null,"isOpen":true,
             "sortOrder":0,"testSetupBundleID":"ts_1"}
            """#
        let decoded = try decoder.decode(BundledAssignment.self, from: Data(json.utf8))
        #expect(decoded.visibility == nil)
        #expect(bundledAssignmentVisibility(decoded) == .open)
    }
}
